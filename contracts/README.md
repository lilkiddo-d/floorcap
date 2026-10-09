# Floorcap contracts

Foundry project. See the repository root README.md, DEPLOY.md and THREAT_MODEL.md.

- `src/`: protocol contracts
- `test/unit`, `test/invariant`, `test/fork`: tests (`forge test`; the fork suite needs network access)
- `script/Deploy.s.sol`: one-shot deploy + wiring + Timelock handover (signs only via `--account floorcap-deployer`)
