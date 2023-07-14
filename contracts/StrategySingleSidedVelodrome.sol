// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

// These are the core Yearn libraries
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@yearnvaults/contracts/BaseStrategy.sol";

interface IERC20Extended {
    function decimals() external view returns (uint8);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);
}

interface IOracle {
    function getPriceUsdcRecommended(address) external view returns (uint256);
}

interface IVelodromeRouter {
    struct Routes {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function getAmountsOut(uint256 amountIn, Routes[] memory routes)
        external
        view
        returns (uint256[] memory amounts);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function quoteRemoveLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity
    ) external view returns (uint256 amountA, uint256 amountB);

    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory,
        uint256 amountADesired,
        uint256 amountBDesired
    )
        external
        view
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidity(
        address,
        address,
        bool,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Routes[] memory routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function quoteStableLiquidityRatio(
        address token0,
        address token1,
        address factory
    ) external view returns (uint256 ratio);
}

interface IVelodromeGauge {
    function deposit(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function withdraw(uint256 amount) external;

    function getReward(address account) external;

    function earned(address account) external view returns (uint256);

    function stakingToken() external view returns (address);
}

interface IVelodromePool is IERC20 {
    function stable() external view returns (bool);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function factory() external view returns (address);

    function getAmountOut(uint256 amountIn, address tokenIn)
        external
        view
        returns (uint256 amount);
}

abstract contract StrategySingleSidedVelodrome is BaseStrategy {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    /// @notice Velodrome pool contract
    IVelodromePool public pool;

    /// @notice Velodrome v2 router contract
    IVelodromeRouter public constant router =
        IVelodromeRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

    // this means all of our fee values are in basis points
    uint256 internal constant FEE_DENOMINATOR = 10000;

    /// @notice The address of our base token (VELO v2)
    IERC20 public constant velo =
        IERC20(0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db);

    uint256 public lastInvest; // default is 0
    uint256 public minTimePerInvest; // = 3600;
    uint256 public maxSingleInvest; // // 2 hbtc per hour default
    uint256 public slippageProtectionIn; // = 50; //out of 10000. 50 = 0.5%
    uint256 public slippageProtectionOut; // = 50; //out of 10000. 50 = 0.5%
    bool public withdrawProtection;

    uint8 public want_decimals;
    uint8 public other_decimals;

    /// @notice Token0 in our pool.
    IERC20 public poolToken0;

    /// @notice Token1 in our pool.
    IERC20 public poolToken1;

    /// @notice Token opposite our want in the pool.
    IERC20 public other;

    /// @notice Factory address that deployed our Velodrome pool.
    address public factory;

    /// @notice True if our pool is stable, false if volatile.
    bool public isStablePool;

    VaultAPI public yvToken;

    /// @notice Our swap route to go from the other token in the pool to our want token.
    /// @dev Struct is from token, to token, and true/false for stable/volatile.
    IVelodromeRouter.Routes[] public swapRouteForWant;

    /// @notice Our swap route to go from our want token to the other token in the pool
    /// @dev Struct is from token, to token, and true/false for stable/volatile.
    IVelodromeRouter.Routes[] public swapRouteForOther;

    /// @notice Minimum profit size in USDC that we want to harvest.
    /// @dev Only used in harvestTrigger.
    uint256 public harvestProfitMinInUsdc;

    /// @notice Maximum profit size in USDC that we want to harvest (ignore gas price once we get here).
    /// @dev Only used in harvestTrigger.
    uint256 public harvestProfitMaxInUsdc;

    /// @notice Will only be true on the original deployed contract and not on clones; we don't want to clone a clone.
    bool public isOriginal = true;

    // we use this to be able to adjust our strategy's name
    string internal stratName;

    uint256 immutable DENOMINATOR = 10_000;

    uint256 dustThreshold = 1e14; // need to set this correctly for usdc and susd

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        uint256 _maxSingleInvest,
        uint256 _minTimePerInvest,
        uint256 _slippageProtectionIn,
        address _pool,
        address _yvToken,
        string memory _strategyName
    ) BaseStrategy(_vault) {
        _initializeStrat(
            _maxSingleInvest,
            _minTimePerInvest,
            _slippageProtectionIn,
            _pool,
            _yvToken,
            _strategyName
        );
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    function initialize(
        address _vault,
        address _strategist,
        uint256 _maxSingleInvest,
        uint256 _minTimePerInvest,
        uint256 _slippageProtectionIn,
        address _pool,
        address _yvToken,
        string memory _strategyName
    ) external {
        //note: initialise can only be called once. in _initialize in BaseStrategy we have: require(address(want) == address(0), "Strategy already initialized");
        _initialize(_vault, _strategist, _strategist, _strategist);
        _initializeStrat(
            _maxSingleInvest,
            _minTimePerInvest,
            _slippageProtectionIn,
            _pool,
            _yvToken,
            _strategyName
        );
    }

    function _initializeStrat(
        uint256 _maxSingleInvest,
        uint256 _minTimePerInvest,
        uint256 _slippageProtectionIn,
        address _pool,
        address _yvToken,
        string memory _strategyName
    ) internal {
        require(want_decimals == 0, "Already Initialized");
        // initialize variables
        maxReportDelay = 7 days; // 7 days in seconds
        healthCheck = 0x3d8F58774611676fd196D26149C71a9142C45296;

        // should be able to get everything from the pool token itself—token0, token1, stable, factory
        poolToken0 = IERC20(pool.token0());
        poolToken1 = IERC20(pool.token1());
        factory = pool.factory();
        isStablePool = pool.stable();

        // set a state var for our "other" address
        if (wantIsToken0()) {
            other = poolToken1;
        } else {
            other = poolToken0;
        }

        // set our strategy's name
        stratName = _strategyName;

        // add approvals on all tokens
        pool.approve(address(router), type(uint256).max);
        poolToken0.approve(address(router), type(uint256).max);
        poolToken1.approve(address(router), type(uint256).max);
        pool.approve(address(yvToken), type(uint256).max);

        if (
            address(want) != address(poolToken0) &&
            address(want) != address(poolToken1)
        ) {
            revert("Want must be a pool token");
        }

        withdrawProtection = true;
        want_decimals = IERC20Extended(address(want)).decimals();
        other_decimals = IERC20Extended(address(other)).decimals();

        swapRouteForWant.push(
            IVelodromeRouter.Routes(
                address(other),
                address(want),
                isStablePool,
                factory
            )
        );
        swapRouteForOther.push(
            IVelodromeRouter.Routes(
                address(other),
                address(want),
                isStablePool,
                factory
            )
        );

        maxSingleInvest = _maxSingleInvest;
        minTimePerInvest = _minTimePerInvest;
        slippageProtectionIn = _slippageProtectionIn;
        slippageProtectionOut = _slippageProtectionIn; // use In to start with to save on stack
        yvToken = VaultAPI(_yvToken);
    }

    function cloneSingleSidedVelodrome(
        address _vault,
        address _strategist,
        uint256 _maxSingleInvest,
        uint256 _minTimePerInvest,
        uint256 _slippageProtectionIn,
        address _pool,
        address _yvToken,
        string memory _strategyName
    ) external returns (address payable newStrategy) {
        require(isOriginal, "Clone inception!");
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        StrategySingleSidedVelodrome(newStrategy).initialize(
            _vault,
            _strategist,
            _maxSingleInvest,
            _minTimePerInvest,
            _slippageProtectionIn,
            _pool,
            _yvToken,
            _strategyName
        );

        emit Cloned(newStrategy);
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    function wantIsToken0() public view returns (bool) {
        return (address(want) == address(poolToken0));
    }

    /// @notice Balance of want sitting in our strategy.
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // from our SSC strategy

    function delegatedAssets() public view override returns (uint256) {
        return vault.strategies(address(this)).totalDebt;
    }

    /// @notice Balance of underlying we will gain on our next harvest
    function claimableProfits() public view returns (uint256 profits) {
        uint256 assets = estimatedTotalAssets();
        uint256 debt = delegatedAssets();

        if (assets > debt) {
            unchecked {
                profits = assets - debt;
            }
        } else {
            profits = 0;
        }
    }

    // returns value of total
    function veloPoolToWant(uint256 _poolAmount)
        public
        view
        returns (uint256 totalWant)
    {
        if (_poolAmount == 0) {
            return 0;
        }

        //amount of want and other for a given amount of LP token
        (uint256 amountToken0, uint256 amountToken1) = balancesOfPool(
            _poolAmount
        );
        uint256 toSwap;

        // determine which token we need to swap
        if (wantIsToken0()) {
            toSwap = amountToken1;
            totalWant = amountToken0;
        } else {
            toSwap = amountToken0;
            totalWant = amountToken1;
        }

        // check what we get swapping other for more want
        totalWant += pool.getAmountOut(toSwap, address(other));
    }

    function wantToPoolToken(uint256 _wantAmount)
        public
        view
        returns (uint256 totalPoolToken)
    {
        if (_wantAmount == 0) {
            return 0;
        }

        // if volatile, just do 50/50
        uint256 amountToKeep = _wantAmount / 2;
        uint256 amountToSwap = _wantAmount - amountToKeep;

        // if stable, do some more fancy math, not as easy as swapping half
        if (isStablePool) {
            uint256 ratio = router.quoteStableLiquidityRatio(
                address(other),
                address(want),
                factory
            );
            amountToKeep = (_wantAmount * ratio) / 1e18; // ratio returned is B / (B + A)
            amountToSwap = _wantAmount - amountToKeep;
        }
        uint256 theoreticalOtherAmount = pool.getAmountOut(
            amountToSwap,
            address(want)
        );

        // check what we get swapping other for more want
        (, , totalPoolToken) = router.quoteAddLiquidity(
            address(other),
            address(want),
            isStablePool,
            factory,
            theoreticalOtherAmount,
            amountToKeep
        );
    }

    function balancesOfPool(uint256 _liquidity)
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = router.quoteRemoveLiquidity(
            address(poolToken0),
            address(poolToken1),
            isStablePool,
            _liquidity
        );
    }

    function poolTokensInYVault() public view returns (uint256) {
        uint256 balance = yvToken.balanceOf(address(this));

        if (yvToken.totalSupply() == 0) {
            //needed because of revert on priceperfullshare if 0
            return 0;
        }

        uint256 pricePerShare = yvToken.pricePerShare();

        // velo tokens are 1e18 decimals
        return (balance * pricePerShare) / 1e18;
    }

    // first get amount of LP tokens we have, then want+non-want in strategy
    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 totalCurveTokens = poolTokensInYVault() +
            pool.balanceOf(address(this));
        return balanceOfWant() + veloPoolToWant(totalCurveTokens);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _debtPayment = _debtOutstanding;

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 currentValue = estimatedTotalAssets();
        uint256 wantBalance = want.balanceOf(address(this));

        if (debt < currentValue) {
            //profit
            _profit = currentValue - debt;
        } else {
            _loss = debt - currentValue;
        }

        uint256 toFree = _debtPayment + _profit;

        if (toFree > wantBalance) {
            toFree = toFree - wantBalance;

            (, uint256 withdrawalLoss) = withdrawSome(toFree);
            //when we withdraw we can lose money in the withdrawal
            if (withdrawalLoss < _profit) {
                _profit = _profit - withdrawalLoss;
            } else {
                _loss = _loss + (withdrawalLoss - _profit);
                _profit = 0;
            }

            wantBalance = want.balanceOf(address(this));

            if (wantBalance < _profit) {
                _profit = wantBalance;
                _debtPayment = 0;
            } else if (wantBalance < _debtPayment + _profit) {
                _debtPayment = wantBalance - _profit;
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        if (lastInvest + minTimePerInvest > block.timestamp) {
            return;
        }

        // Invest the rest of the want
        uint256 _wantToInvest = Math.min(
            want.balanceOf(address(this)),
            maxSingleInvest
        );
        if (_wantToInvest == 0) {
            return;
        }

        // deposit to our pool
        _depositToPool(_wantToInvest);

        // deposit to yearn vault
        yvToken.deposit();
        lastInvest = block.timestamp;
    }

    // DONE AND UPDATED
    function _depositToPool(uint256 _wantAmount) internal {
        // if volatile, just do 50/50
        uint256 amountToKeep = _wantAmount / 2;
        uint256 amountToSwap = _wantAmount - amountToKeep;

        // if stable, do some more fancy math, not as easy as swapping half
        if (isStablePool) {
            uint256 ratio = router.quoteStableLiquidityRatio(
                address(other),
                address(want),
                factory
            );
            amountToKeep = (_wantAmount * ratio) / 1e18; // ratio returned is B / (B + A)
            amountToSwap = _wantAmount - amountToKeep;
        }

        // should have a slippage limit here on swaps between want -> other *********
        uint256 minOtherOut = pool.getAmountOut(amountToSwap, address(want)) *
            ((DENOMINATOR - slippageProtectionIn) / DENOMINATOR);

        // swap want to other
        router.swapExactTokensForTokens(
            amountToSwap,
            minOtherOut,
            swapRouteForOther,
            address(this),
            block.timestamp
        );

        // check and see what we have after swaps
        uint256 wantBalance = want.balanceOf(address(this));
        uint256 otherBalance = other.balanceOf(address(this));

        // calc our want and other minimums
        uint256 wantMin = wantBalance *
            ((DENOMINATOR - slippageProtectionIn) / DENOMINATOR);
        uint256 otherMin = otherBalance *
            ((DENOMINATOR - slippageProtectionIn) / DENOMINATOR);

        // deposit our liquidity, should have minimal remaining in strategy after this
        router.addLiquidity(
            address(want),
            address(other),
            isStablePool,
            wantBalance,
            otherBalance,
            wantMin,
            otherMin,
            address(this),
            block.timestamp
        );
    }

    //safe to enter more than we have
    function withdrawSome(uint256 _amount)
        internal
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBalanceBefore = want.balanceOf(address(this));

        //let's take the amount we need if virtual price is real. Let's add the
        uint256 poolTokensNeeded = wantToPoolToken(_amount);

        uint256 poolBeforeBalance = pool.balanceOf(address(this)); //should be zero but just incase...

        uint256 pricePerFullShare = yvToken.pricePerShare();
        uint256 amountFromVault = (poolTokensNeeded * 1e18) / pricePerFullShare;

        uint256 yBalance = yvToken.balanceOf(address(this));

        if (amountFromVault > yBalance) {
            amountFromVault = yBalance;
            //this is not loss. so we amend amount

            uint256 _poolTokens = (amountFromVault * pricePerFullShare) / 1e18;
            _amount = veloPoolToWant(_poolTokens);
        }

        if (amountFromVault > 0) {
            yvToken.withdraw(amountFromVault);
            if (withdrawProtection) {
                //this tests that we liquidated all of the expected ytokens. Without it if we get back less then will mark it is loss
                require(
                    yBalance - yvToken.balanceOf(address(this)) >=
                        amountFromVault - (1),
                    "YVAULTWITHDRAWFAILED"
                );
            }
        }

        uint256 toWithdraw = pool.balanceOf(address(this)) - poolBeforeBalance;

        if (toWithdraw > 0) {
            // here we should quote our liquidity out to get a best estimate of what we should be getting
            (uint256 wantMin, uint256 otherMin) = balancesOfPool(toWithdraw);

            //if we have less than 18 decimals we need to lower the amount out
            wantMin =
                (toWithdraw * (DENOMINATOR - (slippageProtectionOut))) /
                (DENOMINATOR);
            if (want_decimals < 18) {
                wantMin = wantMin / (10**(uint256(uint8(18) - want_decimals)));
            }

            otherMin =
                (otherMin * (DENOMINATOR - (slippageProtectionOut))) /
                (DENOMINATOR);
            if (other_decimals < 18) {
                otherMin =
                    otherMin /
                    (10**(uint256(uint8(18) - other_decimals)));
            }

            // time for the yoink
            router.removeLiquidity(
                address(want),
                address(other),
                isStablePool,
                toWithdraw,
                wantMin,
                otherMin,
                address(this),
                block.timestamp
            );
        }

        // swap our other to want
        uint256 otherBalance = other.balanceOf(address(this));
        uint256 minWantOut = pool.getAmountOut(otherBalance, address(other)) *
            ((DENOMINATOR - slippageProtectionOut) / DENOMINATOR);

        // swap other to want
        router.swapExactTokensForTokens(
            otherBalance,
            minWantOut,
            swapRouteForWant,
            address(this),
            block.timestamp
        );

        uint256 diff = want.balanceOf(address(this)) - (wantBalanceBefore);

        if (diff > _amount) {
            _liquidatedAmount = _amount;
        } else {
            _liquidatedAmount = diff;
            _loss = _amount - (diff);
        }
    }

    // ssc version
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBal = want.balanceOf(address(this));
        if (wantBal < _amountNeeded) {
            (_liquidatedAmount, _loss) = withdrawSome(
                _amountNeeded - (wantBal)
            );
        }

        _liquidatedAmount = Math.min(
            _amountNeeded,
            _liquidatedAmount + wantBal
        );
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(1e36); //we can request a lot. dont use max because of overflow
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 to_transfer = yvToken.balanceOf(address(this));
        if (to_transfer > 0) {
            yvToken.transfer(_newStrategy, to_transfer);
        }

        to_transfer = pool.balanceOf(address(this));
        if (to_transfer > 0) {
            pool.transfer(_newStrategy, to_transfer);
        }

        to_transfer = other.balanceOf(address(this));
        if (to_transfer > 0) {
            other.transfer(_newStrategy, to_transfer);
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /// @notice Calculates the profit if all claimable assets were sold for USDC (6 decimals).
    /// @dev Uses yearn's lens oracle, if returned values are strange then troubleshoot there.
    /// @return Total return in USDC from taking profits on yToken gains.
    function claimableProfitInUsdc() public view returns (uint256) {
        IOracle yearnOracle = IOracle(
            0xB082d9f4734c535D9d80536F7E87a6f4F471bF65
        ); // yearn lens oracle, need optimism address
        uint256 underlyingPrice = yearnOracle.getPriceUsdcRecommended(
            address(want)
        );

        // Oracle returns prices as 6 decimals, so multiply by claimable amount and divide by token decimals
        return
            (claimableProfits() * underlyingPrice) / (10**yvToken.decimals());
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {}

    /* ========== SETTERS ========== */

    // router
    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    /// @notice Set the maximum loss we will accept (due to slippage or locked funds) on a vault withdrawal.
    /// @dev Generally, this should be zero, and this function will only be used in special/emergency cases.
    /// @param _maxLoss Max percentage loss we will take, in basis points (100% = 10_000).
    //     function setMaxLoss(uint256 _maxLoss) public onlyVaultManagers {
    //         maxLoss = _maxLoss;
    //     }

    /// @notice This allows us to set the dust threshold for our strategy.
    /// @param _dustThreshold This sets what dust is. If we have less than this remaining after withdrawing, accept it as a loss.
    function setDustThreshold(uint256 _dustThreshold)
        external
        onlyVaultManagers
    {
        require(_dustThreshold < 10000, "Your size is too much size");
        dustThreshold = _dustThreshold;
    }

    // from our SSC strategy

    function updateMinTimePerInvest(uint256 _minTimePerInvest)
        public
        onlyVaultManagers
    {
        minTimePerInvest = _minTimePerInvest;
    }

    function updateMaxSingleInvest(uint256 _maxSingleInvest)
        public
        onlyVaultManagers
    {
        maxSingleInvest = _maxSingleInvest;
    }

    function updateSlippageProtectionIn(uint256 _slippageProtectionIn)
        public
        onlyVaultManagers
    {
        slippageProtectionIn = _slippageProtectionIn;
    }

    function updateSlippageProtectionOut(uint256 _slippageProtectionOut)
        public
        onlyVaultManagers
    {
        slippageProtectionOut = _slippageProtectionOut;
    }

    function updateWithdrawProtection(bool _withdrawProtection)
        public
        onlyVaultManagers
    {
        withdrawProtection = _withdrawProtection;
    }
}
