// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;

import "../interfaces/IYieldSource.sol";
import "../external/yearn/IYVaultV2.sol";

import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @title Yield source for a PoolTogether prize pool that generates yield by depositing into Yearn Vaults.
/// @dev This contract inherits from the ERC20 implementation to keep track of users deposits
/// @dev This is a generic contract that will work with main Yearn Vaults. Vaults using v0.3.2 to v0.3.4 included
/// @dev are not compatible, as they had dips in shareValue due to a small miscalculation
/// @notice Yield Source Prize Pools subclasses need to implement this interface so that yield can be generated.
contract YearnV2YieldSource is IYieldSource, ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using AddressUpgradeable for address;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint;

    /// @notice Yearn Vault which manages `token` to generate yield
    IYVaultV2 public vault;

    /// @dev Deposit Token contract address
    IERC20Upgradeable internal token;

    /// @dev Max % of losses that the Yield Source will accept from the Vault in BPS
    uint256 public maxLosses = 0; // 100% would be 10_000

    /// @notice Emitted when asset tokens are supplied to sponsor the yield source
    event Sponsored(
        address indexed user,
        uint256 amount
    );

    /// @notice Emitted when the yield source is initialized
    event YearnV2YieldSourceInitialized(
        IYVaultV2 vault,
        IERC20Upgradeable token,
        uint8 decimals,
        string symbol,
        string name
    );

    /// @notice Emitted when the Max Losses accepted when withdrawing from yVault are changed
    event MaxLossesChanged(
        uint256 newMaxLosses
    );

    /// @notice Emitted when asset tokens are supplied to the yield source
    event SuppliedTokenTo(
        address indexed from,
        uint256 shares,
        uint256 amount,
        address indexed to
    );

    /// @notice Emitted when asset tokens are redeemed from the yield source
    event RedeemedToken(
        address indexed from,
        uint256 shares,
        uint256 amount
    );

    /// @notice Mock Initializer to initialize implementations used by minimal proxies.
    function freeze() public initializer {
        //no-op
    }

    /// @notice Initializes the yield source with
    /// @param _vault Yearn V2 Vault in which the Yield Source will deposit `token` to generate Yield
    /// @param _token Underlying token address (eg: DAI)
    /// @param _decimals Number of decimals the shares (inherited ERC20) will have.  Same as underlying asset to ensure same ExchangeRates.
    /// @param _symbol Token symbol for the underlying ERC20 shares (eg: yvysDAI).
    /// @param _name Token name for the underlying ERC20 shares (eg: PoolTogether Yearn V2 Vault DAI Yield Source).
    function initialize(
        IYVaultV2 _vault,
        IERC20Upgradeable _token,
        uint8 _decimals,
        string calldata _symbol,
        string calldata _name
    )
        public
        initializer
        returns (bool)
    {
        require(address(_vault) != address(0), "YearnV2YieldSource/vault-not-zero-address");
        require(_vault.activation() != uint256(0), "YearnV2YieldSource/vault-not-initialized");

        // NOTE: Vaults from 0.3.2 to 0.3.4 have dips in shareValue
        string memory _vaultAPIVersion = _vault.apiVersion();

        require(!_areEqualStrings(_vaultAPIVersion, "0.3.2"), "YearnV2YieldSource/vault-not-compatible");
        require(!_areEqualStrings(_vaultAPIVersion, "0.3.3"), "YearnV2YieldSource/vault-not-compatible");
        require(!_areEqualStrings(_vaultAPIVersion, "0.3.4"), "YearnV2YieldSource/vault-not-compatible");

        vault = _vault;

        require(address(_token) != address(0), "YearnV2YieldSource/token-not-zero-address");

        address _vaultToken = _vault.token();

        if (_vaultToken != address(0)) {
            require(_vaultToken == address(_token), "YearnV2YieldSource/token-address-different");
        }

        token = _token;

        __Ownable_init();
        __ReentrancyGuard_init();

        __ERC20_init(_name, _symbol);
        require(_decimals > 0, "YearnV2YieldSource/decimals-not-greater-than-zero");
        _setupDecimals(_decimals);

        _token.safeApprove(address(_vault), type(uint256).max);

        emit YearnV2YieldSourceInitialized(
            _vault,
            _token,
            _decimals,
            _symbol,
            _name
        );

        return true;
    }

    /// @notice Approve vault contract to spend max uint256 amount
    /// @dev Emergency function to re-approve max amount if approval amount dropped too low
    /// @return true if operation is successful
    function approveMaxAmount() external onlyOwner returns (bool) {
        address _vault = address(vault);
        IERC20Upgradeable _token = token;
        uint256 allowance = _token.allowance(address(this), _vault);

        _token.safeIncreaseAllowance(_vault, type(uint256).max.sub(allowance));
        return true;
    }

    /// @notice Sets the maximum acceptable loss to sustain on withdrawal.
    /// @dev This function is only callable by the owner of the yield source.
    /// @param _maxLosses Max Losses in double decimal precision.
    /// @return True if maxLosses was set successfully.
    function setMaxLosses(uint256 _maxLosses) external onlyOwner returns(bool) {
        require(_maxLosses <= 10_000, "YearnV2YieldSource/losses-set-too-high");

        maxLosses = _maxLosses;

        emit MaxLossesChanged(_maxLosses);
        return true;
    }

    /// @notice Returns the ERC20 asset token used for deposits
    /// @return The ERC20 asset token address
    function depositToken() external view override returns (address) {
        return address(token);
    }

    /// @notice Returns user total balance (in asset tokens). This includes the deposits and interest.
    /// @param addr User address
    /// @return The underlying balance of asset tokens
    function balanceOfToken(address addr) external override returns (uint256) {
        return _sharesToToken(balanceOf(addr));
    }

    /// @notice Supplies asset tokens to the yield source
    /// @dev Shares corresponding to the number of tokens supplied are mint to the user's balance
    /// @dev Asset tokens are supplied to the yield source, then deposited into Aave
    /// @param _amount The amount of asset tokens to be supplied
    /// @param _to The user whose balance will receive the tokens
    function supplyTokenTo(uint256 _amount, address _to) external override nonReentrant {
        uint256 shares = _tokenToShares(_amount);

        _mint(_to, shares);

        // NOTE: we have to deposit after calculating shares to mint
        token.safeTransferFrom(msg.sender, address(this), _amount);

        _depositInVault();

        emit SuppliedTokenTo(msg.sender, shares, _amount, _to);
    }

    /// @notice Redeems asset tokens from the yield source
    /// @dev Shares corresponding to the number of tokens withdrawn are burnt from the user's balance
    /// @dev Asset tokens are withdrawn from Yearn's Vault, then transferred from the yield source to the user's wallet
    /// @param amount The amount of asset tokens to be redeemed
    /// @return The actual amount of tokens that were redeemed
    function redeemToken(uint256 amount) external override nonReentrant returns (uint256) {
        uint256 shares = _tokenToShares(amount);

        uint256 withdrawnAmount = _withdrawFromVault(amount);

        _burn(msg.sender, shares);

        token.safeTransfer(msg.sender, withdrawnAmount);

        emit RedeemedToken(msg.sender, shares, amount);
        return withdrawnAmount;
    }

    /// @notice Allows someone to deposit into the yield source without receiving any shares
    /// @dev This allows anyone to distribute tokens among the share holders
    /// @param amount The amount of tokens to deposit
    function sponsor(uint256 amount) external nonReentrant {
        token.safeTransferFrom(msg.sender, address(this), amount);

        _depositInVault();

        emit Sponsored(msg.sender, amount);
    }

    // ************************ INTERNAL FUNCTIONS ************************

    /// @notice Deposits full balance (or max available deposit) into Yearn's Vault
    /// @dev if deposit limit is reached, tokens will remain in the Yield Source and
    /// @dev they will be queued for retries in subsequent deposits
    /// @return The actual amount of shares that were received for the deposited tokens
    function _depositInVault() internal returns (uint256) {
        IYVaultV2 v = vault; // NOTE: for gas usage
        IERC20Upgradeable _token = token;

        if (_token.allowance(address(this), address(v)) < _token.balanceOf(address(this))) {
            _token.safeApprove(address(v), type(uint256).max);
        }

        // this will deposit full balance (for cases like not enough room in Vault)
        return v.deposit();
    }

    /// @notice Withdraws requested amount from Vault
    /// @dev Vault withdrawal function required amount of shares to be redeemed
    /// @dev Losses are accepted by the Yield Source to avoid funds being locked in the Vault if something happened
    /// @param amount amount of asset tokens to be redeemed
    /// @return Tokens received from the Vault
    function _withdrawFromVault(uint amount) internal returns (uint256) {
        IERC20Upgradeable _token = token;
        IYVaultV2 _vault = vault;
        uint256 yShares = _tokenToYShares(amount);
        uint256 previousBalance = _token.balanceOf(address(this));

        // we accept losses to avoid being locked in the Vault (if losses happened for some reason)
        uint256 _maxLosses = maxLosses;

        if (_maxLosses != 0) {
            _vault.withdraw(yShares, address(this), _maxLosses);
        } else {
            _vault.withdraw(yShares, address(this));
        }

        uint256 currentBalance = _token.balanceOf(address(this));

        return currentBalance.sub(previousBalance);
    }

    /// @notice Returns the amount of shares of yearn's vault that the Yield Source holds
    /// @return Balance of vault's shares holded by Yield Source
    function _balanceOfYShares() internal view returns (uint256) {
        return vault.balanceOf(address(this));
    }

    /// @notice Ratio between yShares and underlying token
    /// @dev use this to convert from shares to deposit tokens and viceversa
    /// @dev (see _tokenToYShares & _ySharesToToken)
    /// @return Price per vault's share
    function _pricePerYShare() internal view returns (uint256) {
        return vault.pricePerShare();
    }

    /// @notice Balance of deposit token held in the Yield Source
    /// @return balance of deposit token
    function _balanceOfToken() internal view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @notice Total Assets under Management by Yield Source, denominated in Deposit Token
    /// @dev amount of deposit token held in Yield Source + investment (amount held in Yearn's Vault)
    /// @return Total AUM denominated in deposit Token
    function _totalAssetsInToken() internal view returns (uint256) {
        return _balanceOfToken().add(_ySharesToToken(_balanceOfYShares()));
    }

    /// @notice Support function to retrieve used by Vault
    /// @dev used to correctly scale prices
    /// @return decimals of vault's shares (and underlying token)
    function _vaultDecimals() internal view returns (uint256) {
        return vault.decimals();
    }

    // ************************ CALCS ************************

    /// @notice Converter from deposit token to yShares (yearn vault's shares)
    /// @param tokens Amount of tokens to be converted
    /// @return yShares to redeem to receive `tokens` deposit token
    function _tokenToYShares(uint256 tokens) internal view returns (uint256) {
        return tokens.mul(10 ** _vaultDecimals()).div(_pricePerYShare());
    }

    /// @notice Converter from deposit yShares (yearn vault's shares) to token
    /// @param yShares Vault's shares to be converted
    /// @return tokens that will be received if yShares shares are redeemed
    function _ySharesToToken(uint256 yShares) internal view returns (uint256) {
        return yShares.mul(_pricePerYShare()).div(10 ** _vaultDecimals());
    }

    /// @notice Function to calculate the amount of Yield Source shares equivalent to a deposit tokens amount
    /// @param tokens amount of tokens to be converted
    /// @return shares number of shares equivalent to the amount of tokens
    function _tokenToShares(uint256 tokens) internal view returns (uint256 shares) {
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            shares = tokens;
        } else {
            uint256 _totalTokens = _totalAssetsInToken();
            shares = tokens.mul(_totalSupply).div(_totalTokens);
        }
    }

    /// @notice Function to calculate the amount of Deposit Tokens equivalent to a Yield Source shares amount
    /// @param shares amount of Yield Source shares to be converted
    /// @dev used to calculate how many shares to mint / burn when depositing / withdrawing
    /// @return tokens number of tokens equivalent (in value) to the amount of Yield Source shares
    function _sharesToToken(uint256 shares) internal view returns (uint256 tokens) {
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            tokens = shares;
        } else {
            uint256 _totalTokens = _totalAssetsInToken();
            tokens = shares.mul(_totalTokens).div(_totalSupply);
        }
    }

    /// @notice Pure support function to compare strings
    /// @param a One string
    /// @param b Another string
    /// @return Whether or not the strings are the same or not
    function _areEqualStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
}
