## SPDX-License-Identifier: AGPL-3.0-or-later

%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.cairo.common.uint256 import (
    ALL_ONES,
    Uint256,
    uint256_check,
    uint256_eq
)
from starkware.starknet.common.syscalls import (
    get_caller_address,
    get_contract_address
)

from openzeppelin.token.erc20.interfaces.IERC20 import IERC20
from openzeppelin.token.erc20.library import (
    ERC20,
    ERC20_allowances
)
from openzeppelin.security.safemath import uint256_checked_sub_le

from dependencies.erc4626.utils.fixedpointmathlib import mul_div_up, mul_div_down

## @title Generic ERC4626 vault
## @description An ERC4626-style vault implementation.
##              Adapted from the solmate implementation: https://github.com/Rari-Capital/solmate/blob/main/src/mixins/ERC4626.sol
## @author Peteris <github.com/Pet3ris>

#############################################
##                 EVENTS                  ##
#############################################

@event
func Deposit(from_: felt, to: felt, amount: Uint256, shares: Uint256):
end

@event
func Withdraw(from_: felt, to: felt, amount: Uint256, shares: Uint256):
end

#############################################
##                STORAGE                  ##
#############################################

@storage_var
func ERC4626_asset() -> (asset: felt):
end

namespace ERC4626:

    #############################################
    ##               CONSTRUCTOR               ##
    #############################################

    func initializer{
            syscall_ptr: felt*, 
            pedersen_ptr: HashBuiltin*,
            range_check_ptr
        }(
            asset: felt,
            name: felt,
            symbol: felt
        ):
        alloc_locals
        let (decimals) = IERC20.decimals(contract_address=asset)
        ERC20.constructor(name, symbol, decimals)
        ERC4626_asset.write(asset)
        return ()
    end

    #############################################
    ##              MAX ACTIONS                ##
    #############################################

    func max_deposit(to: felt) -> (max_assets: Uint256):
        return (Uint256(ALL_ONES, ALL_ONES))
    end

    func max_mint(to: felt) -> (max_shares: Uint256):
        return (Uint256(ALL_ONES, ALL_ONES))
    end

    func max_redeem{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(caller: felt) -> (max_shares: Uint256):
        return ERC20.balance_of(caller)
    end

    #############################################
    ##                INTERNAL                 ##
    #############################################

    func ERC20_decrease_allowance_manual{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(owner: felt, spender: felt, subtracted_value: Uint256) -> ():
        alloc_locals

        # This is vault logic, we place it here to avoid revoked references at callsite
        if spender == owner:
            return ()
        end

        # This is decrease_allowance, but edited
        with_attr error_message("ERC20: subtracted_value is not a valid Uint256"):
            uint256_check(subtracted_value)
        end

        let (current_allowance: Uint256) = ERC20_allowances.read(owner=owner, spender=spender)

        with_attr error_message("ERC20: allowance below zero"):
            let (new_allowance: Uint256) = uint256_checked_sub_le(current_allowance, subtracted_value)
        end

        ERC20._approve(owner, spender, new_allowance)
        return ()
    end

end


    #############################################
    ##                ERC-20                 ##
    #############################################


@view
func name{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (name : felt):
    let (name) = ERC20.name()
    return (name)
end

@view
func symbol{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (symbol : felt):
    let (symbol) = ERC20.symbol()
    return (symbol)
end

@view
func totalSupply{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    totalSupply : Uint256
):
    let (totalSupply : Uint256) = ERC20.total_supply()
    return (totalSupply)
end

@view
func decimals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    decimals : felt
):
    let (decimals) = ERC20.decimals()
    return (decimals)
end

@view
func balanceOf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    account : felt
) -> (balance : Uint256):
    let (balance : Uint256) = ERC20.balance_of(account)
    return (balance)
end

@view
func allowance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner : felt, spender : felt
) -> (remaining : Uint256):
    let (remaining : Uint256) = ERC20.allowance(owner, spender)
    return (remaining)
end

#
# Externals
#

@external
func transfer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    recipient : felt, amount : Uint256
) -> (success : felt):
    ERC20.transfer(recipient, amount)
    return (TRUE)
end

@external
func transferFrom{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    sender : felt, recipient : felt, amount : Uint256
) -> (success : felt):
    ERC20.transfer_from(sender, recipient, amount)
    return (TRUE)
end

@external
func approve{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    spender : felt, amount : Uint256
) -> (success : felt):
    ERC20.approve(spender, amount)
    return (TRUE)
end