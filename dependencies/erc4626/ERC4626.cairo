# SPDX-License-Identifier: AGPL-3.0-or-later

%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address
from starkware.cairo.common.uint256 import ALL_ONES, Uint256, uint256_check, uint256_eq

from openzeppelin.token.erc20.interfaces.IERC20 import IERC20
from openzeppelin.token.erc20.library import ERC20

from dependencies.erc4626.library import ERC4626, ERC4626_asset, Deposit, Withdraw
from dependencies.erc4626.utils.fixedpointmathlib import mul_div_down, mul_div_up
from dependencies.erc4626.interfaces.IJediSwapPair import IJediSwapPair



# @title Generic ERC4626 vault (copy this to build your own).
# @description An ERC4626-style vault implementation.
#              Adapted from the solmate implementation: https://github.com/Rari-Capital/solmate/blob/main/src/mixins/ERC4626.sol
# @dev When extending this contract, don't forget to incorporate the ERC20 implementation.
# @author Peteris <github.com/Pet3ris>

#############################################
#                CONSTRUCTOR                #
#############################################

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        asset : felt, name : felt, symbol : felt, tokenLP1_ : felt, tokenLP2_, oracle_address : felt, tokenLP1_root, tokenLP2_root : felt):
    ERC4626.initializer(asset, name, symbol)
    tokenLP1.write(tokenLP1_)
    tokenLP1_root.write(tokenLP1_root)
    tokenLP2.write(tokenLP2_)
    tokenLP2.write(tokenLP2_root)
    empiric_oracle.write(oracle_address)

    return ()
end

#############################################
#                 GETTERS                   #
#############################################

@view
func asset{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (asset : felt):
    return ERC4626_asset.read()
end

#############################################
#                 STORAGE                   #
#############################################

@storage_var
func tokenLP1() -> (asset: felt):
end

@storage_var
func tokenLP2() -> (asset: felt):
end

@storage_var
func empiric_oracle() -> (asset: felt):
end


const AGGREGATION_MODE = 0  # default


#############################################
#                  ACTIONS                  #
#############################################

@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        assets : Uint256, receiver : felt) -> (shares : Uint256):
    alloc_locals
    # Check for rounding error since we round down in previewDeposit.
    let (local shares) = previewDeposit(assets)
    with_attr error_message("ERC4626: cannot deposit 0 shares"):
        let ZERO = Uint256(0, 0)
        let (shares_is_zero) = uint256_eq(shares, ZERO)
        assert shares_is_zero = FALSE
    end

    # Need to transfer before minting or ERC777s could reenter.
    let (asset) = ERC4626_asset.read()
    let (local msg_sender) = get_caller_address()
    let (local this) = get_contract_address()
    IERC20.transferFrom(contract_address=asset, sender=msg_sender, recipient=this, amount=assets)

    ERC20._mint(receiver, shares)

    Deposit.emit(msg_sender, receiver, assets, shares)

    _after_deposit(assets, shares)

    return (shares)
end

@external
func mint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        shares : Uint256, receiver : felt) -> (assets : Uint256):
    alloc_locals
    # No need to check for rounding error, previewMint rounds up.
    let (local assets) = previewMint(shares)

    # Need to transfer before minting or ERC777s could reenter.
    let (asset) = ERC4626_asset.read()
    let (local msg_sender) = get_caller_address()
    let (local this) = get_contract_address()
    IERC20.transferFrom(contract_address=asset, sender=msg_sender, recipient=this, amount=assets)

    ERC20._mint(receiver, shares)

    Deposit.emit(msg_sender, receiver, assets, shares)

    _after_deposit(assets, shares)

    return (assets)
end

@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        assets : Uint256, receiver : felt, owner : felt) -> (shares : Uint256):
    alloc_locals
    # No need to check for rounding error, previewWithdraw rounds up.
    let (local shares) = previewWithdraw(assets)

    let (local msg_sender) = get_caller_address()
    ERC4626.ERC20_decrease_allowance_manual(owner, msg_sender, shares)

    _before_withdraw(assets, shares)

    ERC20._burn(owner, shares)

    Withdraw.emit(owner, receiver, assets, shares)

    let (asset) = ERC4626_asset.read()
    IERC20.transfer(contract_address=asset, recipient=receiver, amount=assets)

    return (shares)
end

@external
func redeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        shares : Uint256, receiver : felt, owner : felt) -> (assets : Uint256):
    alloc_locals
    let (local msg_sender) = get_caller_address()
    ERC4626.ERC20_decrease_allowance_manual(owner, msg_sender, shares)

    # Check for rounding error since we round down in previewRedeem.
    let (local assets) = previewRedeem(shares)
    let ZERO = Uint256(0, 0)
    let (assets_is_zero) = uint256_eq(assets, ZERO)
    with_attr error_message("ERC4626: cannot redeem 0 assets"):
        assert assets_is_zero = FALSE
    end

    _before_withdraw(assets, shares)

    ERC20._burn(owner, shares)

    Withdraw.emit(owner, receiver, assets, shares)

    let (asset) = ERC4626_asset.read()
    IERC20.transfer(contract_address=asset, recipient=receiver, amount=assets)

    return (assets)
end

#############################################
#               MAX ACTIONS                 #
#############################################

@view
func maxDeposit(to : felt) -> (maxAssets : Uint256):
    return ERC4626.max_deposit(to)
end

@view
func maxMint(to : felt) -> (maxShares : Uint256):
    return ERC4626.max_mint(to)
end

@view
func maxWithdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        from_ : felt) -> (maxAssets : Uint256):
    let (balance) = ERC20.balance_of(from_)
    return convertToAssets(balance)
end

@view
func maxRedeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        caller : felt) -> (maxShares : Uint256):
    return ERC4626.max_redeem(caller)
end

#############################################
#             PREVIEW ACTIONS               #
#############################################

@view
func previewDeposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        assets : Uint256) -> (shares : Uint256):
    return convertToShares(assets)
end

@view
func previewMint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        shares : Uint256) -> (assets : Uint256):
    alloc_locals
    # Probably not needed
    with_attr error_message("ERC4626: shares is not a valid Uint256"):
        uint256_check(shares)
    end

    let (local supply) = ERC20.total_supply()
    let (local all_assets) = totalAssets()
    let ZERO = Uint256(0, 0)
    let (supply_is_zero) = uint256_eq(supply, ZERO)
    if supply_is_zero == TRUE:
        return (shares)
    end
    let (local z) = mul_div_up(shares, all_assets, supply)
    return (z)
end

@view
func previewWithdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        assets : Uint256) -> (shares : Uint256):
    alloc_locals
    # Probably not needed
    with_attr error_message("ERC4626: assets is not a valid Uint256"):
        uint256_check(assets)
    end

    let (local supply) = ERC20.total_supply()
    let (local all_assets) = totalAssets()
    let ZERO = Uint256(0, 0)
    let (supply_is_zero) = uint256_eq(supply, ZERO)
    if supply_is_zero == TRUE:
        return (assets)
    end
    let (local z) = mul_div_up(assets, supply, all_assets)
    return (z)
end

@view
func previewRedeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        shares : Uint256) -> (assets : Uint256):
    return convertToAssets(shares)
end

#############################################
#             CONVERT ACTIONS               #
#############################################

@view
func convertToShares{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        assets : Uint256) -> (shares : Uint256):
    alloc_locals
    with_attr error_message("ERC4626: assets is not a valid Uint256"):
        uint256_check(assets)
    end

    let (local supply) = ERC20.total_supply()
    let (local allAssets) = totalAssets()
    let ZERO = Uint256(0, 0)
    let (supply_is_zero) = uint256_eq(supply, ZERO)
    if supply_is_zero == TRUE:
        return (assets)
    end
    let (local z) = mul_div_down(assets, supply, allAssets)
    return (z)
end

@view
func convertToAssets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        shares : Uint256) -> (assets : Uint256):
    alloc_locals
    with_attr error_message("ERC4626: shares is not a valid Uint256"):
        uint256_check(shares)
    end

    let (local supply) = ERC20.total_supply()
    let (local allAssets) = totalAssets()
    let ZERO = Uint256(0, 0)
    let (supply_is_zero) = uint256_eq(supply, ZERO)
    if supply_is_zero == TRUE:
        return (shares)
    end
    let (local z) = mul_div_down(shares, allAssets, supply)
    return (z)
end

#############################################
#           HOOKS TO OVERRIDE               #
#############################################

@view
func totalAssets() -> (totalManagedAssets : Uint256):
    let (contract_address) = get_contract_address()
    let (asset_address) = asset()
    let (asset_amount) = IERC20.balance_of(asset_address, contract_address)
    let (tokenLP1_address) = tokenLP1.read()
    let (tokenLP1_amount) = IERC20.balance_of(tokenLP1_address, contract_address)   
    let (tokenLP2_address) = tokenLP2.read()
    let (tokenLP2_amount) = IERC20.balance_of(tokenLP2_address, contract_address)    
    let (oracle_) = empiric_oracle.read()
    let (reserve0_, reserve1_) = IJediSwapPair.get_reserves(tokenLP1_address)
    let (eth_amount_lp1) = convert_to_eth(reserve0_, reserve1_)
    let (reserve2_, reserve3_) = IJediSwapPair.get_reserves(tokenLP1_address)
    let (eth_amount_lp2) = convert_to_eth(reserve2_, reserve3_)

    let (reserve2_

    let (other_asset_price, decimals, timestamp, num_sources_aggregated) = IEmpiricOracle.get_value(
        oracle_, KEY, AGGREGATION_MODE
    )
    return()
    
end

func _before_withdraw(assets : Uint256, shares : Uint256):
    return ()
end

func _after_deposit(assets : Uint256, shares : Uint256):
    return ()
end

#############################################
#                  ERC20                    #
#############################################

@view
func name{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (name : felt):
    let (name) = ERC4626.name()
    return (name)
end

@view
func symbol{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (symbol : felt):
    let (symbol) = ERC4626.symbol()
    return (symbol)
end

@view
func totalSupply{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    totalSupply : Uint256
):
    let (totalSupply : Uint256) = ERC4626.totalSupply()
    return (totalSupply)
end

@view
func decimals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    decimals : felt
):
    let (decimals) = ERC4626.decimals()
    return (decimals)
end

@view
func balanceOf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    account : felt
) -> (balance : Uint256):
    let (balance : Uint256) = ERC4626.balanceOf(account)
    return (balance)
end

@view
func allowance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner : felt, spender : felt
) -> (remaining : Uint256):
    let (remaining : Uint256) = ERC4626.allowance(owner, spender)
    return (remaining)
end

#
# Externals
#

@external
func transfer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    recipient : felt, amount : Uint256
) -> (success : felt):
    ERC4626.transfer(recipient, amount)
    return (TRUE)
end

@external
func transferFrom{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    sender : felt, recipient : felt, amount : Uint256
) -> (success : felt):
    ERC4626.transferFrom(sender, recipient, amount)
    return (TRUE)
end

@external
func approve{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    spender : felt, amount : Uint256
) -> (success : felt):
    ERC4626.approve(spender, amount)
    return (TRUE)
end


#############################################
##                  TASK                   ##
#############################################

@view
func probeTask{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }() -> (taskReady: felt):
    alloc_locals

    let (lastExecuted) = __lastExecuted.read()
    let (block_timestamp) = get_block_timestamp()
    let deadline = lastExecuted + 60
    let (taskReady) = is_le(deadline, block_timestamp)

    return (taskReady=taskReady)
end

@external
func executeTask{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }() -> ():
    # One could call `probeTask` here; it depends
    # entirely on the application.

    let (counter) = __counter.read()
    let new_counter = counter + 1
    let (block_timestamp) = get_block_timestamp()
    __lastExecuted.write(block_timestamp)
    __counter.write(new_counter)
    return ()
end