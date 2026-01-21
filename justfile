slither-mutate:
    slither-mutate src --test-cmd='FOUNDRY_PROFILE=gambit forge test'
test:
    forge bind-json && forge test -vvv
build:
    forge bind-json && forge build
gambit-mutate:
    gambit_runner generate src
gambit-test:
    gambit_runner run --test-cmd 'FOUNDRY_PROFILE=gambit forge test' --build-cmd 'FOUNDRY_PROFILE=gambit forge build'
gambit-uncaught:
    gambit_runner run --test-cmd 'FOUNDRY_PROFILE=gambit forge test' --build-cmd 'FOUNDRY_PROFILE=gambit forge build' --uncaught
gambit-report:
    gambit_runner report
gambit-full:
    gambit_runner full --test-cmd 'FOUNDRY_PROFILE=gambit forge test' --build-cmd 'FOUNDRY_PROFILE=gambit forge build' src
coverage:
    forge coverage --report lcov --exclude-tests && genhtml lcov.info --branch-coverage --output-dir coverage
