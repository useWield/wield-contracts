// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Forward-compat hook for swappable strategies. Not used in v0.
interface IAllocator {
    struct Allocation {
        address asset;
        uint16 bps;
    }

    function execute(Allocation[] calldata allocations) external;
}
