# Neutral controller regression ownership

The device-neutral T01–T30 scenarios, assertion/report schemas, trace vocabulary,
validators and their tests are maintained solely in
[ControlSurfaceKit](https://github.com/NorthBoundWisdom/ControlSurfaceKit/blob/main/docs/controller-regression.md).
The migration preserved the scenario file SHA256:
`546fbc2a6f1d20f9e116a91558f4dd67891bfaba797b9778e85d975fe4cd3384`.

The 24 validator tests moved unchanged to that repository's
`clients/python/tests/test_controller_regression.py`; its CI runs them with both
validators on macOS and Linux. Device executors remain in their host adapters.
SurfacePlugins does not depend on ControlSurfaceKit and keeps ownership of
parameter rules, business plugins and published consumer control-contract
fixtures/checkers. Hosts pin each repository independently using full revisions.
