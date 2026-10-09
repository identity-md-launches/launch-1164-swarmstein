// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SWARMSTEINToken} from "../src/SWARMSTEINToken.sol";
import {PoolManager} from "./vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "./vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "./vendor/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "./vendor/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./vendor/v4-core/src/types/PoolId.sol";
import {Currency} from "./vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "./vendor/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "./vendor/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "./vendor/v4-core/src/libraries/StateLibrary.sol";

/// @notice The ERC-20 subset the launch flows use. Ours, so the test does not inherit a definition
/// from the token under test.
interface IERC20Like {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice IMD, the chain's pair token, placed at its real address so the pool sorts currencies as
/// the chain will. A plain mintable ERC-20; only the harness mints it.
contract PairTokenStandIn {
    string public constant name = "IMD";
    string public constant symbol = "IMD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "IMD: insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Shared settlement against the v4 PoolManager: pay what is owed by sync/transfer/settle
/// and take what is due. Plain ERC-20 transfers from the caller; nothing is exempted.
abstract contract V4Settler is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function _settle(Currency currency, int128 delta) internal {
        if (delta < 0) {
            uint256 owed = uint256(uint128(-delta));
            manager.sync(currency);
            require(
                IERC20Like(Currency.unwrap(currency)).transfer(address(manager), owed), "pay returned false"
            );
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}

/// @notice Stands in for the ProjectFactory: deploys the token (so the token's deployer is this
/// contract), holds the supply, forwards the swarm's share and the remainder, and seeds the pool
/// through the PoolManager's unlock. Only the test may drive it.
contract FactoryStandIn is V4Settler {
    struct Seed {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    address private immutable controller = msg.sender;

    constructor(IPoolManager manager_) V4Settler(manager_) {}

    modifier onlyController() {
        require(msg.sender == controller, "not the harness");
        _;
    }

    function deployToken(bytes32 salt) external onlyController returns (SWARMSTEINToken) {
        return new SWARMSTEINToken{salt: salt}();
    }

    function move(IERC20Like token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external onlyController returns (int24) {
        return manager.initialize(key, sqrtPriceX96);
    }

    function seed(Seed calldata seed_) external onlyController returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(seed_)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        Seed memory s = abi.decode(data, (Seed));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            s.key,
            IPoolManager.ModifyLiquidityParams(
                s.tickLower, s.tickUpper, int256(uint256(s.liquidity)), bytes32(0)
            ),
            ""
        );
        _settle(s.key.currency0, delta.amount0());
        _settle(s.key.currency1, delta.amount1());
        return abi.encode(delta);
    }
}

/// @notice An ordinary trader: not the factory, not the distributor, nothing the token could have
/// any reason to treat specially.
contract Trader is V4Settler {
    PoolKey private key;

    constructor(IPoolManager manager_) V4Settler(manager_) {}

    function swap(PoolKey calldata key_, bool zeroForOne, int256 amountSpecified)
        external
        returns (BalanceDelta)
    {
        key = key_;
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amountSpecified)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta =
            manager.swap(key, IPoolManager.SwapParams(zeroForOne, amountSpecified, limit), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }
}

/// @notice Everything the launch needs, built once: the real v4 PoolManager at its Robinhood Chain
/// address, IMD at its address, the factory stand-in, and the token deployed by the factory.
abstract contract LaunchFixture is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 9_000;
    uint256 constant INITIAL_MARKET_CAP_WEI = 2_500 * 1e18;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint256 constant CHAIN_ID = 4_663;
    uint64 constant LAUNCH_NUMBER = 1;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant REMAINDER_TO = 0x000000000000000000000000000000000000dEaD;
    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);

    IPoolManager manager;
    FactoryStandIn factory;
    SWARMSTEINToken token;
    bool tokenIsCurrency0;

    function setUp() public virtual {
        vm.chainId(CHAIN_ID);

        // v4's manager records the address it was built at, so it is constructed in place.
        vm.etch(POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = POOL_MANAGER.call("");
        require(built && runtime.length > 0, "pool manager could not be built in place");
        vm.etch(POOL_MANAGER, runtime);
        manager = IPoolManager(POOL_MANAGER);
        vm.label(POOL_MANAGER, "PoolManager");

        vm.etch(IMD, address(new PairTokenStandIn()).code);
        vm.label(IMD, "IMD");

        factory = new FactoryStandIn(manager);
        vm.label(address(factory), "ProjectFactory");
        token = factory.deployToken(bytes32(uint256(LAUNCH_NUMBER)));
        vm.label(address(token), "SWARMSTEIN");
        tokenIsCurrency0 = address(token) < IMD;
    }

    function _key(uint24 fee) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(IMD))
            : (Currency.wrap(IMD), Currency.wrap(address(token)));
        return PoolKey(c0, c1, fee, TICK_SPACING, IHooks(address(0)));
    }

    /// @dev sqrt(currency1 per currency0) in Q64.96, derived from the opening market cap and the
    /// supply with the deployed currency order, as the deployer does.
    function _openingSqrtPriceX96() internal view returns (uint160) {
        uint256 ratioX192 = tokenIsCurrency0
            ? FullMath.mulDiv(INITIAL_MARKET_CAP_WEI, 1 << 192, SUPPLY)
            : FullMath.mulDiv(SUPPLY, 1 << 192, INITIAL_MARKET_CAP_WEI);
        return uint160(_sqrt(ratioX192));
    }

    /// @dev A single-sided range holding only the token: entirely above the current tick when the
    /// token is currency0, entirely below it when it is currency1.
    function _seedRange(uint160 sqrtPriceX96) internal view returns (int24 lower, int24 upper) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 floored = _floorToSpacing(tick);
        if (tokenIsCurrency0) {
            lower = floored + TICK_SPACING;
            upper = TickMath.maxUsableTick(TICK_SPACING);
        } else {
            lower = TickMath.minUsableTick(TICK_SPACING);
            upper = floored;
        }
    }

    function _liquidityForTokens(uint256 amount, int24 lower, int24 upper) internal view returns (uint128) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint256 liquidity = tokenIsCurrency0
            ? FullMath.mulDiv(amount, FullMath.mulDiv(sqrtA, sqrtB, 1 << 96), sqrtB - sqrtA)
            : FullMath.mulDiv(amount, 1 << 96, sqrtB - sqrtA);
        // Shave a hair so the manager's round-up never asks for more than the pool share.
        liquidity -= liquidity / 1e9;
        require(liquidity <= type(uint128).max, "liquidity overflow");
        return uint128(liquidity);
    }

    /// @dev The launch as the factory performs it, in order: swarm share to the distributor, pool
    /// initialised at the derived price and seeded single-sided with the requester's pool share,
    /// remainder to remainderTo. Returns the key and what the seed took.
    function _launch(uint24 fee) internal returns (PoolKey memory key, uint256 taken) {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(
            factory.move(IERC20Like(address(token)), DISTRIBUTOR, swarm), "swarm transfer returned false"
        );

        key = _key(fee);
        uint160 sqrtPriceX96 = _openingSqrtPriceX96();
        factory.initialize(key, sqrtPriceX96);
        (int24 lower, int24 upper) = _seedRange(sqrtPriceX96);
        uint256 allowed = (SUPPLY * POOL_BPS) / 10_000;
        uint128 liquidity = _liquidityForTokens(allowed, lower, upper);

        uint256 before = token.balanceOf(address(factory));
        factory.seed(FactoryStandIn.Seed(key, lower, upper, liquidity));
        taken = before - token.balanceOf(address(factory));

        uint256 remainder = token.balanceOf(address(factory));
        assertTrue(
            factory.move(IERC20Like(address(token)), REMAINDER_TO, remainder),
            "remainder transfer returned false"
        );
    }

    function _floorToSpacing(int24 tick) internal pure returns (int24) {
        int24 r = tick % TICK_SPACING;
        if (r < 0) r += TICK_SPACING;
        return tick - r;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

/// @notice The launch flows and a swap each way through the real PoolManager at the launch fee.
contract SWARMSTEINTokenLaunchTest is LaunchFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_constructorMintsTheWholeSupplyToTheFactory() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY, "the factory does not hold the whole supply");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the token sent the swarm share itself");
        assertEq(token.balanceOf(POOL_MANAGER), 0);
        assertEq(token.balanceOf(REMAINDER_TO), 0);
    }

    /// @dev The manifest's provenance price is sqrt(2500 IMD / 1e9 SWARMSTEIN) in Q64.96 with the
    /// token as currency0: the economics and the recorded price agree.
    function test_manifestProvenancePriceMatchesTheEconomics() public pure {
        uint256 provenance = 125270724187523965593206900;
        uint256 derived = _sqrt(FullMath.mulDiv(INITIAL_MARKET_CAP_WEI, 1 << 192, SUPPLY));
        assertApproxEqRel(derived, provenance, 1e9, "launch.json initialPrice disagrees with the economics");
        assertGt(derived, TickMath.MIN_SQRT_PRICE);
        assertLt(derived, TickMath.MAX_SQRT_PRICE);
    }

    function test_launchFlowsMoveExactlyWhatTheySay() public {
        (PoolKey memory key, uint256 taken) = _launch(POOL_FEE);
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 allowed = (SUPPLY * POOL_BPS) / 10_000;

        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "the swarm share arrived short");
        assertEq(token.balanceOf(POOL_MANAGER), taken, "the pool manager holds something other than the seed");
        assertGt(taken, 0, "the seed took nothing");
        assertLe(taken, allowed, "the seed took more than the pool share");
        assertGt(taken, allowed - allowed / 1e6, "the seed took far less than the pool share");
        assertEq(token.balanceOf(REMAINDER_TO), SUPPLY - swarm - taken, "the remainder arrived short");
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something");
        assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(POOL_MANAGER) + token.balanceOf(REMAINDER_TO),
            SUPPLY,
            "the launch flows did not conserve the supply"
        );
        assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");

        // The pool is live at the derived price with the seeded liquidity and the launch fee.
        (uint160 sqrtPriceX96,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, _openingSqrtPriceX96());
        assertEq(lpFee, POOL_FEE);
        assertEq(manager.getLiquidity(key.toId()), 0, "single-sided liquidity should not be in range yet");
    }

    function test_swarmShareIsClaimableWhole() public {
        _launch(POOL_FEE);
        uint256 swarm = token.balanceOf(DISTRIBUTOR);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm), "the claim returned false");
        assertEq(token.balanceOf(CLAIMANT), swarm, "a claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept something back");
    }

    /// @dev An ordinary trader buys with IMD and sells back through the PoolManager at the 1.25%
    /// launch fee. Every token movement to and from the manager is exact; the only loss is the
    /// pool's fee, which stays in the pool.
    function test_traderBuysAndSellsThroughThePoolManagerAtTheLaunchFee() public {
        (PoolKey memory key, uint256 seeded) = _launch(POOL_FEE);
        Trader trader = new Trader(manager);
        uint256 spend = 1 ether;
        PairTokenStandIn(IMD).mint(address(trader), spend);

        // Buy: exact IMD in, token out.
        BalanceDelta buy = trader.swap(key, !tokenIsCurrency0, -int256(spend));
        int128 tokenDelta = tokenIsCurrency0 ? buy.amount0() : buy.amount1();
        int128 imdDelta = tokenIsCurrency0 ? buy.amount1() : buy.amount0();
        assertGt(tokenDelta, 0, "a trader could not buy the token");
        assertEq(imdDelta, -int256(spend), "the buy did not spend exactly the input");
        uint256 bought = uint256(uint128(tokenDelta));
        assertEq(
            token.balanceOf(address(trader)),
            bought,
            "the trader received a different amount than the pool paid"
        );
        assertEq(token.balanceOf(POOL_MANAGER), seeded - bought, "the pool manager lost a different amount");
        assertEq(PairTokenStandIn(IMD).balanceOf(POOL_MANAGER), spend, "the fee did not stay in the pool");
        assertEq(PairTokenStandIn(IMD).balanceOf(address(trader)), 0);

        // The price moved up for the token: the trader paid roughly the opening price plus fee.
        // 1 IMD at 2.5e-6 IMD per token buys 4e23 units before fees; the fee takes 1.25%.
        uint256 feeFree = (spend * SUPPLY) / INITIAL_MARKET_CAP_WEI;
        assertLt(bought, feeFree, "the trader paid no fee");
        assertGt(bought, (feeFree * 98) / 100, "the trader paid far more than the fee");

        // Sell everything back: exact token in, IMD out.
        BalanceDelta sell = trader.swap(key, tokenIsCurrency0, -int256(bought));
        int128 imdBack = tokenIsCurrency0 ? sell.amount1() : sell.amount0();
        assertGt(imdBack, 0, "a trader could not sell the token");
        assertEq(token.balanceOf(address(trader)), 0, "the sell did not take the whole input");
        assertEq(
            token.balanceOf(POOL_MANAGER), seeded, "the pool manager did not get back exactly what was sold"
        );
        uint256 received = uint256(uint128(imdBack));
        assertEq(PairTokenStandIn(IMD).balanceOf(address(trader)), received);
        assertEq(PairTokenStandIn(IMD).balanceOf(POOL_MANAGER), spend - received);

        // Round trip loses the fee twice (1 - 0.9875^2 = 2.48%) plus a sliver of price impact.
        uint256 lossBps = ((spend - received) * 10_000) / spend;
        assertGe(lossBps, 240, "round trip lost less than two fees");
        assertLe(lossBps, 270, "round trip lost much more than two fees");
    }

    /// @dev Exact-output buy: the manager pays out exactly the requested amount, so the token must
    /// not skim what leaves the manager.
    function test_exactOutputBuyDeliversExactlyTheRequestedTokens() public {
        (PoolKey memory key, uint256 seeded) = _launch(POOL_FEE);
        Trader trader = new Trader(manager);
        PairTokenStandIn(IMD).mint(address(trader), 100 ether);
        uint256 want = 123_456_789e12;

        BalanceDelta buy = trader.swap(key, !tokenIsCurrency0, int256(want));
        int128 tokenDelta = tokenIsCurrency0 ? buy.amount0() : buy.amount1();
        assertEq(uint256(uint128(tokenDelta)), want);
        assertEq(token.balanceOf(address(trader)), want, "exact-output delivered a different amount");
        assertEq(token.balanceOf(POOL_MANAGER), seeded - want);
    }

    /// @dev The same trade with and without the launch fee, from the same launch state: the only
    /// difference is the pool's fee on the input, so the token itself charges nothing.
    function test_feeIsChargedByThePoolNotTheToken() public {
        uint256 spend = 1 ether;
        uint256 snapshot = vm.snapshotState();

        (PoolKey memory freeKey,) = _launch(0);
        Trader freeTrader = new Trader(manager);
        PairTokenStandIn(IMD).mint(address(freeTrader), spend);
        freeTrader.swap(freeKey, !tokenIsCurrency0, -int256(spend));
        uint256 boughtWithoutFee = token.balanceOf(address(freeTrader));

        assertTrue(vm.revertToState(snapshot));

        (PoolKey memory key,) = _launch(POOL_FEE);
        Trader trader = new Trader(manager);
        PairTokenStandIn(IMD).mint(address(trader), spend);
        trader.swap(key, !tokenIsCurrency0, -int256(spend));
        uint256 boughtWithFee = token.balanceOf(address(trader));

        assertGt(boughtWithoutFee, 0);
        assertLt(boughtWithFee, boughtWithoutFee, "the launch fee changed nothing");
        // 1.25% of the input is taken as the LP fee; price impact on 1 IMD is far below 0.01%.
        assertApproxEqRel(boughtWithFee, (boughtWithoutFee * 987_500) / 1_000_000, 1e14, "fee is not 1.25%");
    }

    // ------------------------------------------------------------------------------------------
    // Failure paths through the pool
    // ------------------------------------------------------------------------------------------

    /// @dev Until someone has bought, the single-sided pool holds no IMD below the opening price
    /// and a sell swaps nothing. After a buy, a seller who does not hold the tokens is stopped by
    /// the token's own balance check inside the manager's settlement, and nothing moves.
    function test_sellingTokensOneDoesNotHoldRevertsInsideTheManager() public {
        (PoolKey memory key, uint256 seeded) = _launch(POOL_FEE);
        Trader buyer = new Trader(manager);
        PairTokenStandIn(IMD).mint(address(buyer), 1 ether);
        buyer.swap(key, !tokenIsCurrency0, -int256(1 ether));
        uint256 managerBefore = token.balanceOf(POOL_MANAGER);
        assertLt(managerBefore, seeded);

        Trader trader = new Trader(manager);
        uint256 amount = 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientBalance.selector, address(trader), 0, amount)
        );
        trader.swap(key, tokenIsCurrency0, -int256(amount));
        assertEq(token.balanceOf(POOL_MANAGER), managerBefore, "a failed sell changed the pool's balance");
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(PairTokenStandIn(IMD).balanceOf(address(trader)), 0, "a failed sell paid out IMD");
    }

    /// @dev The same empty seller before any buy: the swap finds no IMD-side liquidity, moves
    /// nothing, and the token is never called. Documented so the previous test's ordering is
    /// understood as v4 behaviour, not the token's.
    function test_sellIntoUntouchedSingleSidedPoolMovesNothing() public {
        (PoolKey memory key, uint256 seeded) = _launch(POOL_FEE);
        Trader trader = new Trader(manager);
        BalanceDelta delta = trader.swap(key, tokenIsCurrency0, -int256(1e18));
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
        assertEq(token.balanceOf(POOL_MANAGER), seeded);
    }

    function test_buyingWithoutPairTokenReverts() public {
        (PoolKey memory key, uint256 seeded) = _launch(POOL_FEE);
        Trader trader = new Trader(manager);
        vm.expectRevert(bytes("IMD: insufficient"));
        trader.swap(key, !tokenIsCurrency0, -int256(1 ether));
        assertEq(token.balanceOf(POOL_MANAGER), seeded);
    }

    function test_seedingMoreThanTheFactoryHoldsReverts() public {
        PoolKey memory key = _key(POOL_FEE);
        uint160 sqrtPriceX96 = _openingSqrtPriceX96();
        factory.initialize(key, sqrtPriceX96);
        (int24 lower, int24 upper) = _seedRange(sqrtPriceX96);
        // Liquidity for twice the supply: the manager asks for more than exists.
        uint128 liquidity = _liquidityForTokens(2 * SUPPLY, lower, upper);
        vm.expectRevert();
        factory.seed(FactoryStandIn.Seed(key, lower, upper, liquidity));
        assertEq(token.balanceOf(address(factory)), SUPPLY, "a failed seed moved tokens");
        assertEq(token.balanceOf(POOL_MANAGER), 0);
    }

    function test_nobodyButTheFactoryCanDriveTheStandIn() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("not the harness"));
        factory.move(IERC20Like(address(token)), address(0xBAD), 1);
    }
}

/// @notice Random buys and sells through the pool by an ordinary trader. The token's balance at
/// the manager must track the swap deltas exactly, and the supply must stay split among the
/// distributor, the dead address, the manager and the trader with nothing lost.
contract PoolHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager immutable manager;
    SWARMSTEINToken immutable token;
    Trader public immutable trader;
    PoolKey key;
    bool immutable tokenIsCurrency0;

    uint256 public ghostManagerTokens;
    uint256 public ghostImdIn;
    uint256 public ghostImdOut;
    uint256 public buys;
    uint256 public sells;

    constructor(
        IPoolManager manager_,
        SWARMSTEINToken token_,
        PoolKey memory key_,
        bool tokenIsCurrency0_,
        uint256 seeded
    ) {
        manager = manager_;
        token = token_;
        key = key_;
        tokenIsCurrency0 = tokenIsCurrency0_;
        ghostManagerTokens = seeded;
        trader = new Trader(manager_);
    }

    function buy(uint256 spend) external {
        spend = bound(spend, 1e12, 20 ether);
        PairTokenStandIn(Currency.unwrap(tokenIsCurrency0 ? key.currency1 : key.currency0))
            .mint(address(trader), spend);
        BalanceDelta delta = trader.swap(key, !tokenIsCurrency0, -int256(spend));
        int128 tokenDelta = tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        assertGe(tokenDelta, 0, "a buy took tokens from the trader");
        ghostManagerTokens -= uint256(uint128(tokenDelta));
        ghostImdIn += spend;
        buys++;
    }

    function sell(uint256 fraction) external {
        uint256 held = token.balanceOf(address(trader));
        if (held == 0) return;
        uint256 amount = bound(fraction, 1, held);
        BalanceDelta delta = trader.swap(key, tokenIsCurrency0, -int256(amount));
        int128 tokenDelta = tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        int128 imdDelta = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
        assertEq(tokenDelta, -int256(amount), "a sell did not take exactly the input");
        ghostManagerTokens += amount;
        ghostImdOut += uint256(uint128(imdDelta));
        sells++;
    }
}

contract SWARMSTEINTokenPoolInvariantTest is LaunchFixture {
    PoolHandler handler;
    uint256 seeded;

    function setUp() public override {
        super.setUp();
        PoolKey memory key;
        (key, seeded) = _launch(POOL_FEE);
        handler = new PoolHandler(manager, token, key, tokenIsCurrency0, seeded);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 16
    function invariant_poolManagerBalanceTracksSwapDeltasExactly() public view {
        assertEq(token.balanceOf(POOL_MANAGER), handler.ghostManagerTokens(), "the manager's balance drifted");
        assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(REMAINDER_TO) + token.balanceOf(POOL_MANAGER)
                + token.balanceOf(address(handler.trader())),
            SUPPLY,
            "tokens were lost or created around the pool"
        );
        assertEq(token.totalSupply(), SUPPLY);
        assertLe(token.balanceOf(POOL_MANAGER), seeded, "the pool holds more tokens than were seeded");
        assertEq(
            PairTokenStandIn(IMD).balanceOf(POOL_MANAGER),
            handler.ghostImdIn() - handler.ghostImdOut(),
            "IMD drifted"
        );
    }
}
