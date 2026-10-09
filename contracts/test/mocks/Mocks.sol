// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test-only ERC-20 (also used as the mock project token; never deployed by scripts).
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Chainlink-style aggregator proxy with phases and reverting lookups for missing rounds.
contract MockAggregator {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    uint8 public decimals;
    string public description = "mock";
    uint16 public phase = 1;
    mapping(uint16 => Round[]) internal _rounds;
    bool public revertOnMissing = true;

    constructor(uint8 d) {
        decimals = d;
    }

    function setRevertOnMissing(bool v) external {
        revertOnMissing = v;
    }

    function newPhase() external {
        phase++;
    }

    function push(int256 answer) external returns (uint80 id) {
        return pushAt(answer, block.timestamp);
    }

    function pushAt(int256 answer, uint256 ts) public returns (uint80 id) {
        _rounds[phase].push(Round(answer, ts));
        id = _id(phase, _rounds[phase].length);
    }

    function _id(uint16 p, uint256 n) internal pure returns (uint80) {
        return uint80((uint256(p) << 64) | n);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint16 p = phase;
        while (_rounds[p].length == 0 && p > 1) p--;
        uint256 n = _rounds[p].length;
        require(n > 0, "no data");
        Round memory r = _rounds[p][n - 1];
        uint80 id = _id(p, n);
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        uint16 p = uint16(id >> 64);
        uint256 n = uint256(id) & type(uint64).max;
        if (n == 0 || n > _rounds[p].length) {
            if (revertOnMissing) revert("No data present");
            return (id, 0, 0, 0, id);
        }
        Round memory r = _rounds[p][n - 1];
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }
}

/// @notice Chainlink L2 sequencer uptime feed mock (answer 0 = up).
contract MockSequencer {
    int256 public answer;
    uint256 public startedAt;

    function set(int256 a, uint256 s) external {
        answer = a;
        startedAt = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }
}

/// @notice ERC-4626 vault whose share price can be moved up (yield) or down (loss) by tests.
contract MockVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock Vault", "mVLT") ERC4626(asset_) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev Simulate a loss by burning assets held by the vault.
    function slash(uint256 amount) external {
        MockERC20(asset()).burn(address(this), amount);
    }
}
