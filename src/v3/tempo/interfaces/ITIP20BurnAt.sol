// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITIP20BurnAt
/// @notice The TIP-20 burn-at extension (TIP-1006, active from Tempo's T12 hardfork)
/// @dev Declared locally because the vendored `tempo-std` 0.1.1 `ITIP20` predates it. Matches the
/// upstream `tempo-std` declaration. Fold into `ITIP20` once `tempo-std` is bumped.
interface ITIP20BurnAt {

    /// @notice Returns the role identifier for burning from any unprotected account
    function BURN_AT_ROLE() external view returns (bytes32);

    /// @notice Burns from any unprotected account without checking its transfer policy
    /// @dev Requires BURN_AT_ROLE and an unpaused token
    /// @param from The address to burn tokens from
    /// @param amount The amount of tokens to burn
    function burnAt(address from, uint256 amount) external;

}
