# SPDX-License-Identifier: AGPL-3.0-or-later

%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import(
    get_caller_address,
    get_contract_address,
    get_block_timestamp
)
from starkware.cairo.common.uint256 import ( 
    ALL_ONES,
    Uint256,
    uint256_check,
    uint256_eq ,
    uint256_mul,
    uint256_unsigned_div_rem
)
from starkware.cairo.common.pow import pow

from starkware.cairo.common.math import split_felt, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.alloc import alloc

from openzeppelin.token.erc20.interfaces.IERC20 import IERC20
from openzeppelin.token.erc20.library import ERC20
from openzeppelin.security.safemath import SafeUint256

from dependencies.erc4626.library import ERC4626, Deposit, Withdraw
from dependencies.erc4626.utils.fixedpointmathlib import mul_div_down, mul_div_up
from dependencies.erc4626.interfaces.IJediSwapPair import IJediSwapPair, IJediSwapPairERC20
from dependencies.erc4626.interfaces.IRouter import IRouter

from dependencies.erc4626.interfaces.IEmpiricOracle import IEmpiricOracle



from starkware.cairo.common.uint256 import (
    uint256_le,
)

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
        asset : felt, name : felt, symbol : felt, tokenLP1_ : felt, tokenLP2_, oracle_address : felt , token1_key_ctor:felt, token2_key_ctor:felt):
    ERC4626.initializer(asset, name, symbol)
    tokenLP1.write(tokenLP1_)
    tokenLP2.write(tokenLP2_)
    empiric_oracle.write(oracle_address)
    token1_key.write(token1_key_ctor)
    token2_key.write(token2_key_ctor)
    return ()
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

@storage_var
func token1_key() -> (asset: felt):
end

@storage_var
func token2_key() -> (asset: felt):
end

@storage_var
func router() -> (res:felt):
end

@storage_var
func oracle() -> (res: felt):
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
    let (asset) = ERC4626.get_asset()
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
    let (asset) = ERC4626.get_asset()
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

    let (asset) = ERC4626.get_asset()
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

    let (asset) = ERC4626.get_asset()
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
func convert_lp_to_eth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(lp_amount: Uint256, lp_address: felt) -> (eth_amount : Uint256):
    alloc_locals
    let (asset0_) = IJediSwapPair.token0(lp_address)
    let (asset1_) = IJediSwapPair.token1(lp_address)
    let (token_eth_key) = get_asset_key(lp_address)
    let (reserve0_, reserve1_,_) = IJediSwapPair.get_reserves(lp_address)
    let (contract_address) = get_contract_address()
    let (total_supply_) = IJediSwapPairERC20.totalSupply(contract_address)
    let (asset_) = ERC4626.get_asset()
    let (oracle_) = oracle.read()
    if asset0_ == asset_: 
        let (other_asset_price, decimals, timestamp, num_sources_aggregated) = IEmpiricOracle.get_value(oracle_, token_eth_key, AGGREGATION_MODE)
        let (other_asset_price_uint) = felt_to_uint256(other_asset_price)
        let (amount_in_eth,_) = SafeUint256.div_rem(reserve1_ ,other_asset_price_uint)
        let (lp_price) = mul_div_down(reserve0_, amount_in_eth, total_supply_)
        let (eth_amount) = SafeUint256.mul(lp_price, lp_amount)
        return(eth_amount)
    else:
        let (other_asset_price, decimals, timestamp, num_sources_aggregated) = IEmpiricOracle.get_value(oracle_, token_eth_key, AGGREGATION_MODE)
        let (other_asset_price_uint) = felt_to_uint256(other_asset_price)
        let (amount_in_eth,_) = SafeUint256.div_rem(reserve0_ ,other_asset_price_uint)
        let (lp_price) = mul_div_down(reserve1_, amount_in_eth, total_supply_)
        let (eth_amount) = SafeUint256.mul(lp_price, lp_amount)
        return(eth_amount)
    end
end

@view
func convert_eth_to_lp{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(eth_amount: Uint256, lp_address: felt) -> (lp_amount : Uint256):
    alloc_locals
    let (decimal) = IERC20.decimals(lp_address)
    let (one_lp) = pow(10, decimal)
    let (one_lp_uint256) = felt_to_uint256(one_lp) 

    let (asset_) = ERC4626.get_asset()
    let (decimal_asset) = IERC20.decimals(asset_)
    let (one_asset) = pow(10, decimal_asset)
    let (one_asset_uint256) = felt_to_uint256(one_asset) 

    let (one_lp_uint256) = felt_to_uint256(one_lp) 
    let (one_lp_to_eth) = convert_lp_to_eth(one_lp_uint256, lp_address)
    let (one_eth_to_lp) = mul_div_down(one_asset_uint256, one_lp_uint256, one_lp_to_eth)

    let (lp_amount) = SafeUint256.mul(one_eth_to_lp, eth_amount)
    return(lp_amount)
end

@view
func get_asset_key{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(lp_address) -> (key : felt):
    let (token0 : felt) = tokenLP1.read()
    let (token1 : felt) = tokenLP1.read()
    if lp_address == token0: 
        let (key) = token1_key.read()
        return(key)
    else: 
        let (key) = token2_key.read()
        return(key)
    end
end

@view
func totalAssets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (totalManagedAssets : Uint256):
    alloc_locals
    let (contract_address) = get_contract_address()
    let (asset_address) = ERC4626.get_asset()
    let (asset_amount) = IERC20.balanceOf(asset_address, contract_address)

    let (tokenLP1_address) = tokenLP1.read()
    let (tokenLP1_amount) = IERC20.balanceOf(contract_address,tokenLP1_address)   
    let (tokenLP2_address) = tokenLP2.read()
    let (tokenLP2_amount) = IERC20.balanceOf(contract_address, tokenLP2_address)    

    let (eth_amount_lp1) = convert_lp_to_eth(tokenLP1_amount, tokenLP1_address)
    let (eth_amount_lp2) = convert_lp_to_eth(tokenLP2_amount, tokenLP2_address)

    let (lps_to_eth) = SafeUint256.add(eth_amount_lp1, eth_amount_lp2)
    let (totalManagedAssets) = SafeUint256.add(lps_to_eth, asset_amount)
    return(totalManagedAssets)
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
func share_name{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (name : felt):
    let (name) = ERC4626.name()
    return (name)
end

@view
func share_symbol{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (symbol : felt):
    let (symbol) = ERC4626.symbol()
    return (symbol)
end

@view
func share_totalSupply{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    totalSupply : Uint256
):
    let (totalSupply : Uint256) = ERC4626.totalSupply()
    return (totalSupply)
end

@view
func share_decimals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    decimals : felt
):
    let (decimals) = ERC4626.decimals()
    return (decimals)
end

@view
func share_balanceOf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    account : felt
) -> (balance : Uint256):
    let (balance : Uint256) = ERC4626.balanceOf(account)
    return (balance)
end

@view
func share_allowance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner : felt, spender : felt
) -> (remaining : Uint256):
    let (remaining : Uint256) = ERC4626.allowance(owner, spender)
    return (remaining)
end

#
# Externals
#

@external
func share_transfer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    recipient : felt, amount : Uint256
) -> (success : felt):
    ERC4626.transfer(recipient, amount)
    return (TRUE)
end

@external
func share_transferFrom{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    sender : felt, recipient : felt, amount : Uint256
) -> (success : felt):
    ERC4626.transferFrom(sender, recipient, amount)
    return (TRUE)
end

@external
func share_approve{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
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
    let (contract_address) = get_contract_address()
    let (asset_) = ERC4626.get_asset()
    let (eth_amount) = IERC20.balanceOf(asset_,contract_address)
    let (gross_asset_value) = totalAssets()
    let (asset_reserve_percent) = mul_div_down(eth_amount, Uint256(100,0),gross_asset_value)
    let (is_reserve_too_high) = uint256_le(Uint256(21,0), asset_reserve_percent)
    let (is_reserve_too_low) = uint256_le(asset_reserve_percent, Uint256(19,0))
    let taskReady = is_reserve_too_high + is_reserve_too_low
    return (taskReady=taskReady)
end

@external
func executeTask{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }() -> ():
    alloc_locals
    let (contract_address) = get_contract_address()
    let (asset_) = ERC4626.get_asset()
    let (eth_amount) = IERC20.balanceOf(asset_,contract_address)
    let (gross_asset_value) = totalAssets()
    let (asset_reserve_percent) = mul_div_down(eth_amount, Uint256(100,0),gross_asset_value)
    let (is_reserve_too_high) = uint256_le(Uint256(21,0), asset_reserve_percent)
    let (is_reserve_too_low) = uint256_le(asset_reserve_percent, Uint256(19,0))

    if is_reserve_too_high == 1:
        let (diff) = SafeUint256.sub_le(asset_reserve_percent, Uint256(20,0))
        let (diff_in_eth) =  uint256_percent(gross_asset_value, diff)
        feed_strategy(diff_in_eth) 
        return ()
    else:
        if is_reserve_too_low == 1:
            let (diff) = SafeUint256.sub_le(Uint256(20,0), asset_reserve_percent)
            let (diff_in_eth) =  uint256_percent(gross_asset_value, diff)
            feed_reserve(diff_in_eth) 
            return ()
        else:
            return ()
        end
    end
end

func feed_reserve{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount : Uint256) -> ():
    alloc_locals
    let (asset_) = ERC4626.get_asset()
    let (half_amount,_) = SafeUint256.div_rem(amount, Uint256(2,0))
    let (lp1_) = tokenLP1.read()
    let (lp2_) = tokenLP2.read()

    let (lp_amount1) = convert_eth_to_lp(half_amount, lp1_)
    let (lp_amount2) = convert_eth_to_lp(half_amount, lp2_)
    let (contract_address) = get_contract_address()
    let (deadline) = get_block_timestamp()
    let (router_address) = router.read()
    
    IERC20.approve(contract_address = lp1_, spender = router_address, amount = lp_amount1)
    let (tokenA_) = IJediSwapPair.token0(lp1_)
    let (tokenB_) = IJediSwapPair.token0(lp1_)
    let (amountA1: Uint256, amountB1: Uint256) = IRouter.remove_liquidity(contract_address = router_address, tokenA = tokenA_, tokenB = tokenB_, liquidity = lp_amount1, amountAMin = Uint256(0,0), amountBMin = Uint256(0,0), to = contract_address, deadline = deadline )
    if tokenB_ == asset_:
        IERC20.approve(contract_address = tokenA_, spender = router_address, amount = amountA1)
        let (local path : felt*) = alloc()
        assert [path] = tokenA_
        assert [path+1] = asset_
        let path_len = 2
        IRouter.swap_exact_tokens_for_tokens(contract_address = router_address, amountIn = amountA1, amountOutMin = Uint256(0,0), path_len = path_len, path = path, to = contract_address, deadline = deadline) 
    else:
        IERC20.approve(contract_address = tokenB_, spender = router_address, amount = amountB1)
        let (local path : felt*) = alloc()
        assert [path] = tokenB_
        assert [path+1] = asset_
        let path_len = 2
        IRouter.swap_exact_tokens_for_tokens(contract_address = router_address, amountIn = amountB1, amountOutMin = Uint256(0,0), path_len = path_len, path = path, to = contract_address, deadline = deadline) 
    end

    IERC20.approve(contract_address = lp2_, spender = router_address, amount = lp_amount2)
    let (tokenA2_) = IJediSwapPair.token0(lp2_)
    let (tokenB2_) = IJediSwapPair.token0(lp2_)
    let (amountA2: Uint256, amountB2: Uint256) = IRouter.remove_liquidity(contract_address = router_address, tokenA = tokenA2_, tokenB = tokenB2_, liquidity = lp_amount2, amountAMin = Uint256(0,0), amountBMin = Uint256(0,0), to = contract_address, deadline = deadline )
    if tokenB2_ == asset_:
        IERC20.approve(contract_address = tokenA2_, spender = router_address, amount = amountA2)
        let (local path2 : felt*) = alloc()
        assert [path2] = tokenA_
        assert [path2+1] = asset_
        let path_len = 2
        IRouter.swap_exact_tokens_for_tokens(contract_address = router_address, amountIn = amountA2, amountOutMin = Uint256(0,0), path_len = path_len, path = path2, to = contract_address, deadline = deadline) 
    else:
        IERC20.approve(contract_address = tokenB_, spender = router_address, amount = amountB2)
        let (local path2 : felt*) = alloc()
        assert [path2] = tokenB_
        assert [path2+1] = asset_
        let path_len = 2
        IRouter.swap_exact_tokens_for_tokens(contract_address = router_address, amountIn = amountB1, amountOutMin = Uint256(0,0), path_len = path_len, path = path2, to = contract_address, deadline = deadline) 
    end
    return ()
end

func feed_strategy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount : Uint256) -> ():
    alloc_locals
    let (asset_) = ERC4626.get_asset()

    let (router_address) = router.read()

    let (lp1_) = tokenLP1.read()
    let (token0_lp1) = IJediSwapPair.token0(lp1_)
    let (token1_lp1) = IJediSwapPair.token1(lp1_)
    let token_lp1_other = 0

    if token0_lp1 == asset_:
        token_lp1_other = token0_lp1
        tempvar syscall_ptr = syscall_ptr
        tempvar pedersen_ptr = pedersen_ptr
        tempvar range_check_ptr = range_check_ptr

    else:
        token_lp1_other = token1_lp1
        tempvar syscall_ptr = syscall_ptr
        tempvar pedersen_ptr = pedersen_ptr
        tempvar range_check_ptr = range_check_ptr
    end

    let (lp2_) = tokenLP2.read()
    let (token0_lp2) = IJediSwapPair.token0(lp2_)
    let (token1_lp2) = IJediSwapPair.token1(lp2_)

    let token_lp2_other = 0
    if token0_lp2 == asset_:
        token_lp2_other = token0_lp2
        tempvar syscall_ptr = syscall_ptr
        tempvar pedersen_ptr = pedersen_ptr
        tempvar range_check_ptr = range_check_ptr
    else:
        token_lp2_other = token1_lp2
        tempvar syscall_ptr = syscall_ptr
        tempvar pedersen_ptr = pedersen_ptr
        tempvar range_check_ptr = range_check_ptr
    end


    let (half_amount,_) = SafeUint256.div_rem(amount, Uint256(2,0))
    let (router_) = router.read()
    ## lp1

    let (half_amount_1,_) = SafeUint256.div_rem(half_amount, Uint256(2,0))
    IERC20.approve(asset_, router_, half_amount_1)
    let (deadline) = get_block_timestamp()
    let (local path : felt*) = alloc()
    let (asset) = ERC4626.get_asset()
    assert [path] = asset
    assert [path+1] = token_lp1_other
    let path_len = 2
    let (contract_address) = get_contract_address()
    let (amounts_len: felt, amounts: Uint256*) = IRouter.swap_exact_tokens_for_tokens(contract_address = router_address, amountIn = half_amount_1, amountOutMin = Uint256(0,0), path_len = path_len, path = path, to = contract_address, deadline = deadline) 

    IERC20.approve(contract_address = asset, spender = router_address, amount = half_amount_1)
    IERC20.approve(contract_address = token_lp1_other, spender = router_address, amount = [amounts])
    let (amounts_uint) = uint256_to_felt([amounts])
    IRouter.add_liquidity(contract_address = router_address, tokenA = asset, tokenB = amounts_uint, amountADesired = half_amount_1, amountBDesired = [amounts], amountAMin = Uint256(0,0), amountBMin = Uint256(0,0), to = contract_address, deadline = deadline )

    ## lp2

    IERC20.approve(asset_, router_, half_amount_1)
    let (deadline) = get_block_timestamp()
    let (local path2 : felt*) = alloc()
    assert [path2] = asset
    assert [path2+1] = token_lp2_other
    let path_len = 2
    let (amounts2_len: felt, amounts2: Uint256*) = IRouter.swap_exact_tokens_for_tokens(contract_address = router_address, amountIn = half_amount_1, amountOutMin = Uint256(0,0), path_len = path_len, path = path, to = contract_address, deadline = deadline) 

    IERC20.approve(contract_address = asset, spender = router_address, amount = half_amount_1)
    IERC20.approve(contract_address = token_lp2_other, spender = router_address, amount = [amounts2])
    IRouter.add_liquidity(contract_address = router_address, tokenA = asset, tokenB = token_lp2_other, amountADesired = half_amount_1, amountBDesired = [amounts], amountAMin = Uint256(0,0), amountBMin = Uint256(0,0), to = contract_address, deadline = deadline )
    return ()
end


#############################################
##                 UTILS                   ##
#############################################


func uint256_percent{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    x : Uint256, percent : Uint256
) -> (res : Uint256):
    alloc_locals
    let (mul, _high) = uint256_mul(x, percent)
    let (hundred) = felt_to_uint256(100)
    let (res,_) = uint256_unsigned_div_rem(mul, hundred)
    return (res=res)
end

func felt_to_uint256{range_check_ptr}(x) -> (x_ : Uint256):
    let split = split_felt(x)
    return (Uint256(low=split.low, high=split.high))
end


func uint256_to_felt{range_check_ptr}(x : Uint256) -> (res : felt):
    return (res=x.high * (2 ** 128) + x.low)
end
