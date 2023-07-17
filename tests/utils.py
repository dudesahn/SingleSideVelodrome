import pytest
import brownie
from brownie import interface, chain, accounts, ZERO_ADDRESS, Contract

# returns (profit, loss) of a harvest
def harvest_strategy(
    use_yswaps,
    strategy,
    token,
    gov,
    profit_whale,
    profit_amount,
    destination_strategy,
):

    # reset everything with a sleep and mine
    chain.sleep(1)
    chain.mine(1)

    # add in any custom logic needed here, for instance with router strategy (also reason we have a destination strategy).
    # also add in any custom logic needed to get raw reward assets to the strategy (like for liquity)

    ####### ADD LOGIC AS NEEDED FOR CLAIMING/SENDING REWARDS TO STRATEGY #######
    # usually this is automatic, but it may need to be externally triggered

    # if we have zero debt then we are potentially taking profit (when closing out a strategy) then we will need to ignore health check
    # we also may have profit and no assets in edge cases
    vault = interface.IVaultFactory045(strategy.vault())
    if vault.strategies(strategy)["totalDebt"] == 0:
        strategy.setDoHealthCheck(False, {"from": gov})
        print("\nTurned off health check!\n")

    # we can use the tx for debugging if needed
    tx = strategy.harvest({"from": gov})
    profit = tx.events["Harvested"]["profit"]
    loss = tx.events["Harvested"]["loss"]

    # our trade handler takes action, sending out rewards tokens and sending back in profit, but don't need it here.
    extra = 0

    # reset everything with a sleep and mine
    chain.sleep(1)
    chain.mine(1)

    # return our profit, loss, extra value from trade handler
    return (profit, loss, extra)


# simulate the trade handler sweeping out assets and sending back profit
def trade_handler_action(
    strategy,
    token,
    gov,
    profit_whale,
    profit_amount,
):
    ####### ADD LOGIC AS NEEDED FOR SENDING REWARDS OUT AND PROFITS IN #######
    # not needed for velodrome
    return


# do a check on our strategy and vault of choice
def check_status(
    strategy,
    vault,
):
    # check our current status
    strategy_params = vault.strategies(strategy)
    vault_assets = vault.totalAssets()
    debt_outstanding = vault.debtOutstanding(strategy)
    credit_available = vault.creditAvailable(strategy)
    total_debt = vault.totalDebt()
    share_price = vault.pricePerShare()
    strategy_debt = strategy_params["totalDebt"]
    strategy_loss = strategy_params["totalLoss"]
    strategy_gain = strategy_params["totalGain"]
    strategy_debt_ratio = strategy_params["debtRatio"]
    strategy_assets = strategy.estimatedTotalAssets()

    # check our want and other balance
    other = interface.IERC20(strategy.other())
    want = interface.IERC20(strategy.want())
    print("\n🚨 Want Balance:", want.balanceOf(strategy) / 1e18, "🚨")
    print("🚨 Other Balance:", other.balanceOf(strategy) / 1e18, "🚨\n")

    # print our stuff
    print("Vault Assets:", vault_assets)
    print("Strategy Debt Outstanding:", debt_outstanding)
    print("Strategy Credit Available:", credit_available)
    print("Vault Total Debt:", total_debt)
    print("Vault Share Price:", share_price)
    print("Strategy Total Debt:", strategy_debt)
    print("Strategy Total Loss:", strategy_loss)
    print("Strategy Total Gain:", strategy_gain)
    print("Strategy Debt Ratio:", strategy_debt_ratio)
    print("Strategy Estimated Total Assets:", strategy_assets, "\n")

    # print simplified versions if we have something more than dust
    token = interface.IERC20(vault.token())
    if vault_assets > 10:
        print(
            "Decimal-Corrected Vault Assets:", vault_assets / (10 ** token.decimals())
        )
    if debt_outstanding > 10:
        print(
            "Decimal-Corrected Strategy Debt Outstanding:",
            debt_outstanding / (10 ** token.decimals()),
        )
    if credit_available > 10:
        print(
            "Decimal-Corrected Strategy Credit Available:",
            credit_available / (10 ** token.decimals()),
        )
    if total_debt > 10:
        print(
            "Decimal-Corrected Vault Total Debt:", total_debt / (10 ** token.decimals())
        )
    if share_price > 10:
        print("Decimal-Corrected Share Price:", share_price / (10 ** token.decimals()))
    if strategy_debt > 10:
        print(
            "Decimal-Corrected Strategy Total Debt:",
            strategy_debt / (10 ** token.decimals()),
        )
    if strategy_loss > 10:
        print(
            "Decimal-Corrected Strategy Total Loss:",
            strategy_loss / (10 ** token.decimals()),
        )
    if strategy_gain > 10:
        print(
            "Decimal-Corrected Strategy Total Gain:",
            strategy_gain / (10 ** token.decimals()),
        )
    if strategy_assets > 10:
        print(
            "Decimal-Corrected Strategy Total Assets:",
            strategy_assets / (10 ** token.decimals()),
        )

    return strategy_params
