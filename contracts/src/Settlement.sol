// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISeriesFactory} from "./interfaces/ISeriesFactory.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";
import {IOptionsAdapter} from "./interfaces/IOptionsAdapter.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {Note} from "./Note.sol";

/// @title Settlement
/// @notice Maturity settlement at the US close, note redemption, and early exit at mark-to-market.
/// @dev Payout per note = (bond leg redeemed + reserve top-up up to the floor) pro-rata in stablecoin, plus the
///      call payoff pro-rata in kind (basket stock tokens worth participation x gain at the settlement level).
contract Settlement is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    struct Result {
        uint256 level; // basket level at maturity close
        uint256 cash; // stablecoin available to note holders
        uint256 notes; // live notes at settlement (pro-rata denominator)
        uint256 payoutUnits; // basket units received from the options adapter
        uint256 reserveUsed; // shortfall covered by the FeeCollector reserve
        uint64 settledAt;
        bool manual;
    }

    ISeriesFactory public immutable factory;
    uint256 public manualSettlementDelay = 7 days;

    mapping(uint256 => Result) internal _results;
    mapping(uint256 => uint256[]) internal _tokenPayouts;

    event Settled(
        uint256 indexed seriesId,
        uint256 level,
        uint256 cash,
        uint256 notes,
        uint256 payoutUnits,
        uint256 reserveUsed,
        bool manual
    );
    event Claimed(uint256 indexed seriesId, address indexed account, uint256 notes, uint256 cash, uint256[] tokens);
    event EarlyExit(
        uint256 indexed seriesId, address indexed account, uint256 notes, uint256 cash, uint256[] tokens, uint256 cashFee
    );
    event ManualDelaySet(uint256 delay);

    error WrongState();
    error NotMatured();
    error Matured();
    error TooEarlyForManual();
    error MarketClosed();
    error Expired();
    error Slippage(uint256 minOut, uint256 got);
    error ZeroAmount();
    error InvalidLevel();
    error InvalidDelay();

    constructor(address admin, address factory_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        factory = ISeriesFactory(factory_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function setManualSettlementDelay(uint256 delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (delay < 3 days || delay > 30 days) revert InvalidDelay();
        manualSettlementDelay = delay;
        emit ManualDelaySet(delay);
    }

    // ================================================================= settlement

    /// @notice Permissionless settlement at the oracle price of the maturity close (proven with round hints).
    function settle(uint256 id, uint80[] calldata primaryHints, uint80[] calldata secondaryHints)
        external
        nonReentrant
        whenNotPaused
    {
        ISeriesFactory.Series memory s = factory.getSeries(id);
        if (s.state != ISeriesFactory.State.Locked) revert WrongState();
        if (block.timestamp < s.maturity) revert NotMatured();
        uint256 level = factory.basketLevelAt(id, s.maturity, primaryHints, secondaryHints);
        _settle(id, s, level, false);
    }

    /// @notice Last-resort settlement when the oracle cannot produce a valid close price. Only the Timelock
    ///         (48h public delay) and only `manualSettlementDelay` after maturity.
    function settleManual(uint256 id, uint256 level) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        ISeriesFactory.Series memory s = factory.getSeries(id);
        if (s.state != ISeriesFactory.State.Locked) revert WrongState();
        if (block.timestamp < uint256(s.maturity) + manualSettlementDelay) revert TooEarlyForManual();
        if (level == 0) revert InvalidLevel();
        _settle(id, s, level, true);
    }

    function _settle(uint256 id, ISeriesFactory.Series memory s, uint256 level, bool manual) internal {
        uint256 notes = s.liveNotes;
        factory.markSettled(id);

        uint256 cash = IYieldAdapter(s.yieldAdapter).withdrawShare(id, 1, 1, address(this));
        uint256 floorOwed = Math.mulDiv(notes, s.protectionBps, BPS);
        uint256 reserveUsed = 0;
        if (cash < floorOwed) {
            reserveUsed = IFeeCollector(factory.feeCollector()).coverShortfall(s.stable, floorOwed - cash);
            cash += reserveUsed;
        }

        (uint256 payoutUnits, uint256[] memory received) = _exerciseAll(id, s.optionsAdapter, level);

        _results[id] = Result({
            level: level,
            cash: cash,
            notes: notes,
            payoutUnits: payoutUnits,
            reserveUsed: reserveUsed,
            settledAt: uint64(block.timestamp),
            manual: manual
        });
        _tokenPayouts[id] = received;
        emit Settled(id, level, cash, notes, payoutUnits, reserveUsed, manual);
    }

    /// @dev Exercises every open call at `level` and closes the series on the options adapter.
    function _exerciseAll(uint256 id, address optionsAdapter, uint256 level)
        internal
        returns (uint256 payoutUnits, uint256[] memory received)
    {
        address[] memory tokens = factory.basketTokens(id);
        uint256[] memory before = _balances(tokens);
        IOptionsAdapter opt = IOptionsAdapter(optionsAdapter);
        payoutUnits = opt.exercise(id, opt.openUnits(id), level, address(this));
        opt.closeSeries(id);
        received = _balances(tokens);
        for (uint256 i; i < tokens.length; ++i) {
            received[i] -= before[i];
        }
    }

    /// @notice Burn settled notes for their pro-rata cash + in-kind upside. Never pausable.
    function claim(uint256 id, uint256 amount) external nonReentrant returns (uint256 cash, uint256[] memory out) {
        if (amount == 0) revert ZeroAmount();
        if (factory.seriesState(id) != ISeriesFactory.State.Settled) revert WrongState();
        Result memory r = _results[id];
        Note(factory.note()).burn(msg.sender, id, amount);

        cash = Math.mulDiv(r.cash, amount, r.notes);
        uint256[] memory pay = _tokenPayouts[id];
        out = new uint256[](pay.length);
        for (uint256 i; i < pay.length; ++i) {
            out[i] = Math.mulDiv(pay[i], amount, r.notes);
        }
        emit Claimed(id, msg.sender, amount, cash, out);

        ISeriesFactory.Series memory s = factory.getSeries(id);
        if (cash > 0) IERC20(s.stable).safeTransfer(msg.sender, cash);
        address[] memory tokens = factory.basketTokens(id);
        for (uint256 i; i < tokens.length; ++i) {
            if (out[i] > 0) IERC20(tokens[i]).safeTransfer(msg.sender, out[i]);
        }
    }

    // ================================================================= early exit

    /// @notice Exit before maturity at mark-to-market: pro-rata bond-leg value now plus the calls' intrinsic value
    ///         at the live oracle price (in kind), minus the series exit fee. Regular US session only.
    function earlyExit(uint256 id, uint256 amount, uint256 minCashOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 cashOut, uint256[] memory tokensOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amount == 0) revert ZeroAmount();
        ISeriesFactory.Series memory s = factory.getSeries(id);
        if (s.state != ISeriesFactory.State.Locked) revert WrongState();
        if (block.timestamp >= s.maturity) revert Matured();
        if (!IMarketClock(factory.clock()).isTradingSession(block.timestamp)) revert MarketClosed();

        uint256 cash;
        (cash, tokensOut) = _unwind(id, s, amount);

        address fc = factory.feeCollector();
        uint256 cashFee = cash * s.exitFeeBps / BPS;
        cashOut = cash - cashFee;
        if (cashOut < minCashOut) revert Slippage(minCashOut, cashOut);
        _payTokensNetOfFee(id, tokensOut, s.exitFeeBps, fc);
        emit EarlyExit(id, msg.sender, amount, cashOut, tokensOut, cashFee);
        if (cashFee > 0) {
            IERC20(s.stable).safeTransfer(fc, cashFee);
            IFeeCollector(fc).recordFee(s.stable, cashFee, false);
        }
        if (cashOut > 0) IERC20(s.stable).safeTransfer(msg.sender, cashOut);
    }

    /// @dev Burns the notes, then redeems their pro-rata bond leg and exercises their pro-rata calls at the live
    ///      level. Returns gross cash and gross in-kind payouts received by this contract.
    function _unwind(uint256 id, ISeriesFactory.Series memory s, uint256 amount)
        internal
        returns (uint256 cash, uint256[] memory received)
    {
        uint256 level = factory.basketLevelLatest(id);
        uint256 live = s.liveNotes;
        IOptionsAdapter opt = IOptionsAdapter(s.optionsAdapter);
        uint256 units = Math.mulDiv(opt.openUnits(id), amount, live);

        // effects
        Note(factory.note()).burn(msg.sender, id, amount);
        factory.reduceLive(id, amount);

        // interactions with protocol-owned adapters
        cash = IYieldAdapter(s.yieldAdapter).withdrawShare(id, amount, live, address(this));
        address[] memory tokens = factory.basketTokens(id);
        uint256[] memory before = _balances(tokens);
        // payout measured by balance delta, robust to adapter rounding
        // slither-disable-next-line unused-return
        opt.exercise(id, units, level, address(this));
        received = _balances(tokens);
        for (uint256 i; i < tokens.length; ++i) {
            received[i] -= before[i];
        }
    }

    /// @dev Takes the exit fee from each in-kind payout (in place) and pays the rest to the caller.
    function _payTokensNetOfFee(uint256 id, uint256[] memory amounts, uint256 feeBps, address fc) internal {
        address[] memory tokens = factory.basketTokens(id);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 fee = amounts[i] * feeBps / BPS;
            amounts[i] -= fee;
            if (fee > 0) {
                IERC20(tokens[i]).safeTransfer(fc, fee);
                IFeeCollector(fc).recordFee(tokens[i], fee, false);
            }
            if (amounts[i] > 0) IERC20(tokens[i]).safeTransfer(msg.sender, amounts[i]);
        }
    }

    // ================================================================= views

    function resultOf(uint256 id) external view returns (Result memory r, uint256[] memory tokenPayouts) {
        return (_results[id], _tokenPayouts[id]);
    }

    /// @notice Mark-to-market of `amount` notes now, net of the exit fee. Value is in USD (1e18).
    /// @dev Uses the live oracle; reverts if prices are stale. For settled series returns the claim value.
    function previewValue(uint256 id, uint256 amount)
        external
        view
        returns (uint256 cash, uint256[] memory tokensOut, uint256 valueUsd)
    {
        ISeriesFactory.Series memory s = factory.getSeries(id);
        (address[] memory tokens, uint256[] memory qty) = factory.getBasket(id);
        tokensOut = new uint256[](tokens.length);
        uint256 scale = 10 ** (18 - IERC20Metadata(s.stable).decimals());
        IOracleAdapter oracle = IOracleAdapter(factory.oracle());

        if (s.state == ISeriesFactory.State.Settled) {
            Result memory r = _results[id];
            // note count, not a manipulable balance
            // slither-disable-next-line incorrect-equality
            if (r.notes == 0) return (0, tokensOut, 0);
            cash = Math.mulDiv(r.cash, amount, r.notes);
            uint256[] memory pay = _tokenPayouts[id];
            for (uint256 i; i < tokens.length; ++i) {
                tokensOut[i] = Math.mulDiv(pay[i], amount, r.notes);
            }
        } else if (s.state == ISeriesFactory.State.Locked) {
            if (s.liveNotes == 0) return (0, tokensOut, 0);
            uint256 gross = Math.mulDiv(IYieldAdapter(s.yieldAdapter).totalAssets(id), amount, s.liveNotes);
            cash = gross - gross * s.exitFeeBps / BPS;
            uint256 level = factory.basketLevelLatest(id);
            if (level > s.strike) {
                uint256 units = Math.mulDiv(IOptionsAdapter(s.optionsAdapter).openUnits(id), amount, s.liveNotes);
                uint256 payoutUnits = Math.mulDiv(units, level - s.strike, level);
                for (uint256 i; i < tokens.length; ++i) {
                    uint256 g = Math.mulDiv(payoutUnits, qty[i], WAD);
                    tokensOut[i] = g - g * s.exitFeeBps / BPS;
                }
            }
        } else {
            return (0, tokensOut, 0);
        }

        valueUsd = cash * scale;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokensOut[i] > 0) {
                // updatedAt already validated by the adapter
                // slither-disable-next-line unused-return
                (uint256 px,) = oracle.latestPrice(tokens[i]);
                valueUsd += Math.mulDiv(tokensOut[i], px, WAD);
            }
        }
    }

    function _balances(address[] memory tokens) internal view returns (uint256[] memory b) {
        b = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            b[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }
}
