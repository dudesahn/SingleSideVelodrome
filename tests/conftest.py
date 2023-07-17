import pytest
from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
from eth_abi import encode_single
import requests
import os

# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def isolate(fn_isolation):
    pass


# set this for if we want to use tenderly or not; mostly helpful because with brownie.reverts fails in tenderly forks.
use_tenderly = False

# use this to set what chain we use. 1 for ETH, 250 for fantom, 10 optimism, 42161 arbitrum
chain_used = 10


################################################## TENDERLY DEBUGGING ##################################################

# change autouse to True if we want to use this fork to help debug tests
@pytest.fixture(scope="session", autouse=use_tenderly)
def tenderly_fork(web3, chain):
    # Get env variables
    TENDERLY_ACCESS_KEY = os.environ.get("TENDERLY_ACCESS_KEY")
    TENDERLY_USER = os.environ.get("TENDERLY_USER")
    TENDERLY_PROJECT = os.environ.get("TENDERLY_PROJECT")

    # Construct request
    url = f"https://api.tenderly.co/api/v1/account/{TENDERLY_USER}/project/{TENDERLY_PROJECT}/fork"
    headers = {"X-Access-Key": str(TENDERLY_ACCESS_KEY)}
    data = {
        "network_id": str(chain.id),
    }

    # Post request
    response = requests.post(url, json=data, headers=headers)

    # Parse response
    fork_id = response.json()["simulation_fork"]["id"]

    # Set provider to your new Tenderly fork
    fork_rpc_url = f"https://rpc.tenderly.co/fork/{fork_id}"
    tenderly_provider = web3.HTTPProvider(fork_rpc_url, {"timeout": 600})
    web3.provider = tenderly_provider
    print(
        f"https://dashboard.tenderly.co/{TENDERLY_USER}/{TENDERLY_PROJECT}/fork/{fork_id}"
    )


################################################ UPDATE THINGS BELOW HERE ################################################

#################### FIXTURES BELOW NEED TO BE ADJUSTED FOR THIS REPO ####################


@pytest.fixture(scope="session")
def token():
    token_address = "0xdFA46478F9e5EA86d57387849598dbFB2e964b02"  # this should be the address of the ERC-20 used by the strategy/vault (MAI)
    yield interface.IERC20(token_address)


# mai token: 0xdFA46478F9e5EA86d57387849598dbFB2e964b02


@pytest.fixture(scope="function")
def whale(amount, token):
    # Totally in it for the tech
    # Update this with a large holder of your want token (the largest EOA holder of LP)
    whale = accounts.at(
        "0x0000000000000000000000000000000000000001", force=True
    )  # 0x0000000000000000000000000000000000000001, burn address, holds ~1.7m MAI

    if token.balanceOf(whale) < 2 * amount:
        raise ValueError(
            "Our whale needs more funds. Find another whale or reduce your amount variable."
        )
    yield whale


# this is the amount of funds we have our whale deposit. adjust this as needed based on their wallet balance
@pytest.fixture(scope="function")
def amount(token):
    amount = 300_000 * 10 ** token.decimals()  # 300k for MAI
    yield amount


@pytest.fixture(scope="function")
def profit_whale(profit_amount, token):
    # ideally not the same whale as the main whale, or else they will lose money
    profit_whale = accounts.at(
        "0xdFA46478F9e5EA86d57387849598dbFB2e964b02", force=True
    )  # 0xdFA46478F9e5EA86d57387849598dbFB2e964b02, MAI token, holds ~1m MAI for some reason
    if token.balanceOf(profit_whale) < 5 * profit_amount:
        raise ValueError(
            "Our profit whale needs more funds. Find another whale or reduce your profit_amount variable."
        )
    yield profit_whale


@pytest.fixture(scope="function")
def profit_amount(token):
    profit_amount = 100 * 10 ** token.decimals()
    yield profit_amount


@pytest.fixture(scope="session")
def to_sweep(crv):
    # token we can sweep out of strategy (use CRV)
    yield crv


# set address if already deployed, use ZERO_ADDRESS if not
@pytest.fixture(scope="session")
def vault_address():
    vault_address = "0x6759574667896a453304897993D61F00FdC7214d"  # MAI: 0x6759574667896a453304897993D61F00FdC7214d
    yield vault_address


# if our vault is pre-0.4.3, this will affect a few things
@pytest.fixture(scope="session")
def old_vault():
    old_vault = False
    yield old_vault


# this is the name we want to give our strategy
@pytest.fixture(scope="session")
def strategy_name():
    strategy_name = "StrategySingleSidedVelodrome"
    yield strategy_name


# this is the name of our strategy in the .sol file
@pytest.fixture(scope="session")
def contract_name(StrategySingleSidedVelodrome):
    contract_name = StrategySingleSidedVelodrome
    yield contract_name


# if our strategy is using ySwaps, then we need to donate profit to it from our profit whale
@pytest.fixture(scope="session")
def use_yswaps():
    use_yswaps = False
    yield use_yswaps


# whether or not a strategy is clonable. if true, don't forget to update what our cloning function is called in test_cloning.py
@pytest.fixture(scope="session")
def is_clonable():
    is_clonable = True
    yield is_clonable


# use this to test our strategy in case there are no profits
@pytest.fixture(scope="session")
def no_profit():
    no_profit = False
    yield no_profit


# use this when we might lose a few wei on conversions between want and another deposit token (like router strategies)
# generally this will always be true if no_profit is true, even for curve/convex since we can lose a wei converting
@pytest.fixture(scope="session")
def is_slippery(no_profit):
    is_slippery = False  # set this to true or false as needed
    if no_profit:
        is_slippery = True
    yield is_slippery


# use this to set the standard amount of time we sleep between harvests.
# generally 1 day, but can be less if dealing with smaller windows (oracles) or longer if we need to trigger weekly earnings.
@pytest.fixture(scope="session")
def sleep_time():
    hour = 3600

    # change this one right here
    hours_to_sleep = 12

    sleep_time = hour * hours_to_sleep
    yield sleep_time


#################### FIXTURES ABOVE NEED TO BE ADJUSTED FOR THIS REPO ####################

#################### FIXTURES BELOW SHOULDN'T NEED TO BE ADJUSTED FOR THIS REPO ####################


@pytest.fixture(scope="session")
def tests_using_tenderly():
    yes_or_no = use_tenderly
    yield yes_or_no


# by default, pytest uses decimals, but in solidity we use uints, so 10 actually equals 10 wei (1e-17 for most assets, or 1e-6 for USDC/USDT)
@pytest.fixture(scope="session")
def RELATIVE_APPROX(token):
    approx = 10
    print("Approx:", approx, "wei")
    yield approx


# use this to set various fixtures that differ by chain
if chain_used == 1:  # mainnet

    @pytest.fixture(scope="session")
    def gov():
        yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)

    @pytest.fixture(scope="session")
    def health_check():
        yield interface.IHealthCheck("0xddcea799ff1699e98edf118e0629a974df7df012")

    @pytest.fixture(scope="session")
    def base_fee_oracle():
        yield interface.IBaseFeeOracle("0xfeCA6895DcF50d6350ad0b5A8232CF657C316dA7")

    # set all of the following to SMS, just simpler
    @pytest.fixture(scope="session")
    def management():
        yield accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)

    @pytest.fixture(scope="session")
    def rewards(management):
        yield management

    @pytest.fixture(scope="session")
    def guardian(management):
        yield management

    @pytest.fixture(scope="session")
    def strategist(management):
        yield management

    @pytest.fixture(scope="session")
    def keeper(management):
        yield management

    @pytest.fixture(scope="session")
    def trade_factory():
        yield Contract("0xcADBA199F3AC26F67f660C89d43eB1820b7f7a3b")

    @pytest.fixture(scope="session")
    def keeper_wrapper():
        yield Contract("0x0D26E894C2371AB6D20d99A65E991775e3b5CAd7")

elif chain_used == 10:  # optimism

    @pytest.fixture(scope="session")
    def gov():
        yield accounts.at("0xF5d9D6133b698cE29567a90Ab35CfB874204B3A7", force=True)

    @pytest.fixture(scope="session")
    def health_check():
        yield interface.IHealthCheck("0x3d8F58774611676fd196D26149C71a9142C45296")

    @pytest.fixture(scope="session")
    def base_fee_oracle():
        yield interface.IBaseFeeOracle("0xbf4A735F123A9666574Ff32158ce2F7b7027De9A")

    # set all of the following to Scream Guardian MS
    @pytest.fixture(scope="session")
    def management():
        yield accounts.at("0xea3a15df68fCdBE44Fdb0DB675B2b3A14a148b26", force=True)

    @pytest.fixture(scope="session")
    def rewards(management):
        yield management

    @pytest.fixture(scope="session")
    def guardian(management):
        yield management

    @pytest.fixture(scope="session")
    def strategist(management):
        yield management

    @pytest.fixture(scope="session")
    def keeper(management):
        yield management

    @pytest.fixture(scope="session")
    def to_sweep():
        # token we can sweep out of strategy (use VELO v2)
        yield interface.IERC20("0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db")

    @pytest.fixture(scope="session")
    def registry():
        yield Contract("0x79286Dd38C9017E5423073bAc11F53357Fc5C128")


@pytest.fixture(scope="function")
def vault(pm, gov, rewards, guardian, management, token, vault_address):
    if vault_address == ZERO_ADDRESS:
        Vault = pm(config["dependencies"][0]).Vault
        vault = guardian.deploy(Vault)
        vault.initialize(token, gov, rewards, "", "", guardian)
        vault.setDepositLimit(2**256 - 1, {"from": gov})
        vault.setManagement(management, {"from": gov})
    else:
        vault = interface.IVaultFactory045(vault_address)
    yield vault


#################### FIXTURES ABOVE SHOULDN'T NEED TO BE ADJUSTED FOR THIS REPO ####################

#################### FIXTURES BELOW LIKELY NEED TO BE ADJUSTED FOR THIS REPO ####################

# use this similarly to how we use use_yswaps
@pytest.fixture(scope="session")
def is_gmx():
    yield False


@pytest.fixture(scope="session")
def target():
    # whatever we want it to be—this is passed into our harvest function as a target
    yield 69


# this should be a strategy from a different vault to check during migration
@pytest.fixture(scope="session")
def other_strategy():
    yield Contract("0x4809143428Ed49D08978aDF209A4179d52ce5371")


# replace the first value with the name of your strategy
@pytest.fixture(scope="function")
def strategy(
    strategist,
    keeper,
    vault,
    gov,
    management,
    health_check,
    contract_name,
    strategy_name,
    base_fee_oracle,
    vault_address,
    pool,
    pool_vault,
):
    strategy = gov.deploy(
        contract_name,
        vault,
        500_000e18,
        1,
        50,
        pool,
        pool_vault,
        strategy_name,
    )

    # set our management fee to zero so it doesn't mess with our profit checking
    vault.setManagementFee(0, {"from": gov})
    vault.setPerformanceFee(0, {"from": gov})

    # close out debt for all other strategies
    for x in range(20):
        strategy_address = vault.withdrawalQueue(x)
        if strategy_address == ZERO_ADDRESS:
            break
        vault.updateStrategyDebtRatio(strategy_address, 0, {"from": gov})
        other_strat = Contract(strategy_address)
        other_strat.harvest({"from": gov})

    vault.addStrategy(strategy, 10_000, 0, 2**256 - 1, 0, {"from": gov})
    print("Existing Vault, SSV Strategy")
    chain.sleep(1)
    chain.mine(1)

    # turn our oracle into testing mode by setting the provider to 0x00, then forcing true
    strategy.setBaseFeeOracle(base_fee_oracle, {"from": management})
    base_fee_oracle.setBaseFeeProvider(
        ZERO_ADDRESS, {"from": base_fee_oracle.governance()}
    )
    base_fee_oracle.setManualBaseFeeBool(True, {"from": base_fee_oracle.governance()})
    assert strategy.isBaseFeeAcceptable() == True

    yield strategy


#################### FIXTURES ABOVE LIKELY NEED TO BE ADJUSTED FOR THIS REPO ####################

####################         PUT UNIQUE FIXTURES FOR THIS REPO BELOW         ####################

# the velodrome pool we are targeting
@pytest.fixture(scope="session")
def pool():
    yield "0xBE418771bC91F75C4d2BcE1d5E2b7286F50992da"


# the velodrome pool we are targeting
@pytest.fixture(scope="session")
def pool_vault():
    yield "0x68f2B1db2DA6204489279a8fC681f83728bB9622"


@pytest.fixture(scope="session")
def dola():
    yield "0x8aE125E8653821E851F12A49F7765db9a9ce7384"
