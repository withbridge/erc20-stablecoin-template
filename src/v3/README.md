# Stablecoin Template V3

-   Upgraded OZ implementation to v5
    -   `AccessControlEnumerableUpgradeable` instead of `AccessControlUpgradeable`
    -   migrate to ERC20's `_update` vs `_beforeTokenTransfer`
    -   migrate to custom errors vs string reverts
    -   migrate to `setMaxSupply` vs `{increase,decrease}MaxSupply`
    -   migrate to EIP7201 storage layout
-   Can be deployed via the Deterministic Proxy Factory
    -   UUPS -> BeaconProxy (immutable beacon) -> UpgradeableBeacon -> Implementation
    -   Developers can fully own their tokens later while Bridge can manage upgrades for all tokens on a chain in the meantime via an UpgradeableBeacon.
