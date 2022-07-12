// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./vendor/@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import "./vendor/@uniswap/v3-periphery/contracts/base/PeripheryPayments.sol";
import "./vendor/@uniswap/v3-periphery/contracts/base/PeripheryImmutableState.sol";
import "./vendor/@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "./vendor/@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol";
import "./vendor/@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "./vendor/@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../CometInterface.sol";
import "../ERC20.sol";

/**
 * @title Compound's Liquidator Contract
 * @author Compound
 */
contract Liquidator is IUniswapV3FlashCallback, PeripheryImmutableState, PeripheryPayments {
    /** Events **/
    event Absorb(address indexed initiator, address[] accounts);
    event Pay(address token, address indexed payer, address indexed recipient, uint256 value);
    event Swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn);

    /** Structs needed for Uniswap flash swap **/
    struct FlashParams {
        address[] accounts;
        address pairToken;
        uint24 poolFee;
    }

    struct FlashCallbackData {
        uint256 amount;
        address payer;
        PoolAddress.PoolKey poolKey;
        address[] assets;
        uint256[] baseAmounts;
    }

    struct UniswapPoolConfig {
        address asset;
        bool isLowLiquidity;
        uint24 fee;
    }

    /** Liquidator configuration constants **/

    /// @notice The scale for asset price calculations
    uint256 public constant QUOTE_PRICE_SCALE = 1e6;

    /// @notice Uniswap standard pool fee, used if custom fee is not specified for the pool
    uint24 public constant DEFAULT_POOL_FEE = 500;

    /// @notice Uniswap router used for token exchange
    ISwapRouter public immutable swapRouter;

    /// @notice Compound Comet protocol
    CometInterface public immutable comet;

    /// @notice Minimum available amount for liquidation in USDC (base token)
    uint256 public immutable liquidationThreshold;

    /// @notice The address of WETH asset
    address public immutable weth;

    UniswapPoolConfig[] public poolConfigs;

    /** Uniswap pools properties **/
    mapping(address => uint24) public poolFees;
    mapping(address => bool) public isLowLiquidity;

    /**
     * @notice Construct a new liquidator instance
     * @param _swapRouter The Uniswap V3 Swap router address
     * @param _comet The Compound V3 Comet instance address
     * @param _factory The Uniswap V3 pools factory instance address
     * @param _WETH9 The WETH address
     * @param _poolConfigs The configurations of Uniswap asset pools
     **/
    constructor(
        ISwapRouter _swapRouter,
        CometInterface _comet,
        address _factory,
        address _WETH9,
        uint256 _liquidationThreshold,
        UniswapPoolConfig[] memory _poolConfigs
    ) PeripheryImmutableState(_factory, _WETH9) {
        swapRouter = _swapRouter;
        comet = _comet;
        weth = _WETH9;
        liquidationThreshold = _liquidationThreshold;

        poolConfigs = _poolConfigs;
    }

    /**
     * @dev Returns Uniswap pool config for given asset
     */
    function getPoolConfigForAsset(address asset) internal view returns(UniswapPoolConfig memory) {
        for (uint8 i = 0; i < poolConfigs.length; i++) {
            UniswapPoolConfig memory poolConfig = poolConfigs[i];
            if (poolConfig.asset == asset) {
                return poolConfig;
            }
        }

        // If asset is not found, proceed with default pool config
        return UniswapPoolConfig({
            fee: 500,
            asset: asset,
            isLowLiquidity: false
        });
    }

    /**
     * @dev Swaps the given asset to USDC(base token) using Uniswap pools
     */
    function swapCollateral(address asset) internal returns (uint256) {
        uint256 swapAmount = ERC20(asset).balanceOf(address(this));
        // Safety check, make sure residue balance in protocol is ignored
        if (swapAmount == 0) return 0;

        UniswapPoolConfig memory poolConfig = getPoolConfigForAsset(asset);
        uint24 poolFee = poolConfig.fee;
        address swapToken = asset;

        address baseToken = comet.baseToken();

        TransferHelper.safeApprove(asset, address(swapRouter), swapAmount);
        // For low liquidity asset, swap it to ETH first
        if (poolConfig.isLowLiquidity) {
            swapAmount = swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: asset,
                    tokenOut: weth,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: swapAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            emit Swap(asset, weth, poolFee, swapAmount);
            swapToken = weth;
            poolFee = getPoolConfigForAsset(weth).fee;

            TransferHelper.safeApprove(weth, address(swapRouter), swapAmount);
        }

        // Swap asset or received ETH to base asset
        uint256 amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: swapToken,
                tokenOut: baseToken,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: swapAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        emit Swap(swapToken, baseToken, poolFee, swapAmount);

        return amountOut;
    }

    /**
     * @notice Uniswap flashloan callback
     * @param fee0 The fee for borrowing token0 from pool
     * @param fee1 The fee for borrowing token1 from pool
     * @param data The encoded data passed from loan initiation function
     */
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override {
        // Verify uniswap callback, recommended security measure
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);

        address[] memory assets = decoded.assets;

        // Allow Comet protocol to withdraw USDC(base token) for collateral purchase
        TransferHelper.safeApprove(comet.baseToken(), address(comet), decoded.amount);

        uint256 totalAmountOut = 0;
        for (uint i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 baseAmount = decoded.baseAmounts[i];

            if (baseAmount == 0) continue;

            // XXX if buyCollateral returns collateral amount after change in Comet, no need to check balance
            comet.buyCollateral(asset, 0, baseAmount, address(this));
            uint256 amountOut = swapCollateral(asset);
            totalAmountOut += amountOut;
        }

        // We borrow only 1 asset, so one of fees will be 0
        uint256 fee = fee0 + fee1;
        // Payback flashloan to Uniswap pool and profit to the caller
        payback(decoded.amount, fee, comet.baseToken(), totalAmountOut, decoded.payer);
    }

    /**
     * @dev Returns loan to Uniswap pool and sends USDC (base token) profit to caller
     * @param amount The loan amount that need to be repaid
     * @param fee The fee for taking the loan
     * @param token The base token whch was borrowed for successful liquidation
     * @param amountOut The total amount of base token received after liquidation
     * @param payer The caller address of liquidation bot
     */
    function payback(
        uint256 amount,
        uint256 fee,
        address token,
        uint256 amountOut,
        address payer
    ) internal {
        uint256 amountOwed = amount + fee;
        TransferHelper.safeApprove(token, address(this), amountOwed);

        // Repay the loan
        if (amountOwed > 0) {
            pay(token, address(this), msg.sender, amountOwed);
            emit Pay(token, address(this), msg.sender, amountOwed);
        }

        // If profitable, pay profits to the caller
        if (amountOut > amountOwed) {
            uint256 profit = amountOut - amountOwed;
            TransferHelper.safeApprove(token, address(this), profit);
            pay(token, address(this), payer, profit);
            emit Pay(token, address(this), payer, profit);
        }
    }

    /**
     * @dev Calculates the total amount of base asset needed to buy all the discounted collateral from the protocol
     */
    function calculateTotalBaseAmount() internal view returns (uint256, uint256[] memory, address[] memory) {
        uint256 totalBaseAmount = 0;
        uint8 numAssets = comet.numAssets();
        uint256[] memory assetBaseAmounts = new uint256[](numAssets);
        address[] memory cometAssets = new address[](numAssets);
        for (uint8 i = 0; i < numAssets; i++) {
            address asset = comet.getAssetInfo(i).asset;
            cometAssets[i] = asset;
            uint256 collateralBalance = comet.collateralBalanceOf(address(comet), asset);

            if (collateralBalance == 0) continue;

            // Find the price in asset needed to base QUOTE_PRICE_SCALE of USDC(base token) of collateral
            uint256 quotePrice = comet.quoteCollateral(asset, QUOTE_PRICE_SCALE * comet.baseScale());
            uint256 assetBaseAmount = comet.baseScale() * QUOTE_PRICE_SCALE * collateralBalance / quotePrice;

            // Liquidate only positions with adequate gains, no need to collect residue from protocol
            if (assetBaseAmount < liquidationThreshold) continue;

            assetBaseAmounts[i] = assetBaseAmount;
            totalBaseAmount += assetBaseAmount;
        }

        return (totalBaseAmount, assetBaseAmounts, cometAssets);
    }

    /**
     * @notice Calls the pools flash function with data needed in `uniswapV3FlashCallback`
     * @param params The parameters necessary for flash and the callback, passed in as FlashParams
     */
    function initFlash(FlashParams memory params) external {
        // Absorb Comet underwater accounts
        comet.absorb(address(this), params.accounts);
        emit Absorb(msg.sender, params.accounts);

        (uint256 totalBaseAmount, uint256[] memory assetBaseAmounts, address[] memory cometAssets) = calculateTotalBaseAmount();

        address poolToken0 = params.pairToken;
        address poolToken1 = comet.baseToken();
        bool reversedPair = poolToken0 > poolToken1;
        // Use Uniswap approach to determining order of tokens https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/PoolAddress.sol#L20-L27
        if (reversedPair) (poolToken0, poolToken1) = (poolToken1, poolToken0);

        // Find the desired Uniswap pool to borrow base token from, for ex DAI-USDC
        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: poolToken0, token1: poolToken1, fee: params.poolFee});
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        // recipient of borrowed amounts
        // amount of token0 requested to borrow, 0 for non reversed pair
        // amount of token1 requested to borrow, 0 for reversed pair
        // need amount in callback to pay back pool
        // need assets addresses to buy collateral from protocol
        // need baseAmounts to buy collateral from protocol
        // recipient of flash should be THIS contract
        pool.flash(
            address(this),
            reversedPair ? totalBaseAmount : 0,
            reversedPair ? 0 : totalBaseAmount,
            abi.encode(
                FlashCallbackData({
                    amount: totalBaseAmount,
                    payer: msg.sender,
                    poolKey: poolKey,
                    assets: cometAssets,
                    baseAmounts: assetBaseAmounts
                })
            )
        );
    }
}
