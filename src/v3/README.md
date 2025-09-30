# Stablecoin Template V3

-   Upgraded OZ implementation vs [`StablecoinTemplateV2`](../../contracts/v2/StablecoinTemplateV2.sol)
    -   `AccessControlEnumerableUpgradeable` instead of `AccessControlUpgradeable`
    -   migrate to ERC20's `_update` vs `_beforeTokenTransfer`
    -   migrate to custom errors vs string reverts
    -   migrate to `setMaxSupply` vs `{increase,decrease}MaxSupply`
    -   migrate to EIP7201 storage layout
-   Will be deployed via the Deterministic Proxy Factory

    -   UUPS -> BeaconProxy (immutable beacon) -> UpgradeableBeacon -> Implementation
    -   Developers can fully own their tokens later while Bridge can manage upgrades for all tokens on a chain in the meantime via an UpgradeableBeacon.

-   Only **new** tokens - OZ namespaced storage is not compatible with old storage. They will be handled separately.
-   Will use 6 decimals

## Note

If you use Nomic's Solidity extension in vscode/cursor, you may need to delete the `hardhat.config.ts` for LSP to work.
