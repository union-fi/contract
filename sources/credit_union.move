module credit_union::credit_union {
    use std::signer;
    use std::vector;
    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_framework::event;
    use aptos_framework::timestamp;

    // Errors
    const E_NOT_INITIALIZED: u64 = 1;
    const E_ALREADY_MEMBER: u64 = 2;
    const E_NOT_MEMBER: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_CANNOT_WITHDRAW_STAKED: u64 = 5;
    const E_INTEREST_RATE_OUT_OF_BOUNDS: u64 = 6;

    // Struct definitions

    struct CreditUnion has key {
        name: vector<u8>,
        members: vector<address>,
        total_deposits: u64,
        min_interest_rate: u64,
        max_interest_rate: u64,
        signer_cap: account::SignerCapability,
    }

    struct MemberAccount has key {
        balance: u64,
        staked_amount: u64,
    }

    struct Loan has key {
        borrower: address,
        amount: u64,
        interest_rate: u64,
        due_date: u64,
        vouchers: vector<Voucher>,
    }

    struct Voucher has store {
        voucher: address,
        amount: u64,
        interest_rate: u64,
    }

    // Events

    #[event]
    struct UnionCreatedEvent has drop, store, copy {
        creator: address,
        name: vector<u8>,
    }

    #[event]
    struct MemberJoinedEvent has drop, store, copy {
        union: address,
        member: address,
    }

    #[event]
    struct DepositEvent has drop, store, copy {
        union: address,
        member: address,
        amount: u64,
    }

    #[event]
    struct WithdrawEvent has drop, store, copy {
        union: address,
        member: address,
        amount: u64,
    }

    #[event]
    struct LoanRequestedEvent has drop, store, copy {
        union: address,
        borrower: address,
        amount: u64,
    }

    #[event]
    struct LoanApprovedEvent has drop, store, copy {
        union: address,
        borrower: address,
        amount: u64,
        interest_rate: u64,
    }

    // Functions

    public fun create_union(creator: &signer, name: vector<u8>, min_rate: u64, max_rate: u64) {
        let (union_signer, signer_cap) = account::create_resource_account(creator, name);

        let union = CreditUnion {
            name,
            members: vector::empty(),
            total_deposits: 0,
            min_interest_rate: min_rate,
            max_interest_rate: max_rate,
            signer_cap,
        };
        move_to(&union_signer, union);

        // Emit UnionCreatedEvent
        let creator_addr = signer::address_of(creator);
        event::emit(UnionCreatedEvent { creator: creator_addr, name });
    }

    public entry fun join_union(account: &signer, union_addr: address) acquires CreditUnion {
        let union = borrow_global_mut<CreditUnion>(union_addr);
        let member_addr = signer::address_of(account);
        assert!(!vector::contains(&union.members, &member_addr), E_ALREADY_MEMBER);

        vector::push_back(&mut union.members, member_addr);
        move_to(account, MemberAccount { balance: 0, staked_amount: 0 });

        // Emit MemberJoinedEvent
        event::emit(MemberJoinedEvent { union: union_addr, member: member_addr });
    }

    public entry fun deposit<CoinType>(account: &signer, union_addr: address, amount: u64) acquires CreditUnion, MemberAccount {
        let union = borrow_global_mut<CreditUnion>(union_addr);
        let member_addr = signer::address_of(account);
        assert!(vector::contains(&union.members, &member_addr), E_NOT_MEMBER);

        let coin = coin::withdraw<CoinType>(account, amount);
        let union_signer = account::create_signer_with_capability(&union.signer_cap);
        coin::deposit(signer::address_of(&union_signer), coin);

        let member_account = borrow_global_mut<MemberAccount>(member_addr);
        member_account.balance = member_account.balance + amount;
        union.total_deposits = union.total_deposits + amount;

        // Emit DepositEvent
        event::emit(DepositEvent { union: union_addr, member: member_addr, amount });
    }

    public fun withdraw<CoinType>(
        account: &signer,
        union_addr: address,
        amount: u64
    ): coin::Coin<CoinType> acquires CreditUnion, MemberAccount {
        let union = borrow_global_mut<CreditUnion>(union_addr);
        let member_addr = signer::address_of(account);
        assert!(vector::contains(&union.members, &member_addr), E_NOT_MEMBER);

        let member_account = borrow_global_mut<MemberAccount>(member_addr);
        assert!(member_account.balance >= amount, E_INSUFFICIENT_BALANCE);
        assert!(member_account.balance - amount >= member_account.staked_amount, E_CANNOT_WITHDRAW_STAKED);

        member_account.balance = member_account.balance - amount;
        union.total_deposits = union.total_deposits - amount;

        let union_signer = account::create_signer_with_capability(&union.signer_cap);
        let withdrawn_coin = coin::withdraw<CoinType>(&union_signer, amount);

        // Emit WithdrawEvent
        event::emit(WithdrawEvent { union: union_addr, member: member_addr, amount });

        withdrawn_coin
    }

    public entry fun withdraw_to_wallet<CoinType>(
        account: &signer,
        union_addr: address,
        amount: u64
    ) acquires CreditUnion, MemberAccount {
        let withdrawn_coin = withdraw<CoinType>(account, union_addr, amount);
        let account_addr = signer::address_of(account);
        coin::deposit(account_addr, withdrawn_coin);
    }

    public entry fun request_loan(account: &signer, union_addr: address, amount: u64) acquires CreditUnion {
        let union = borrow_global<CreditUnion>(union_addr);
        let borrower = signer::address_of(account);
        assert!(vector::contains(&union.members, &borrower), E_NOT_MEMBER);

        let loan = Loan {
            borrower,
            amount,
            interest_rate: 0, // Will be set when approved
            due_date: 0, // Will be set when approved
            vouchers: vector::empty(),
        };
        move_to(account, loan);

        // Emit LoanRequestedEvent
        event::emit(LoanRequestedEvent { union: union_addr, borrower, amount });
    }

    public entry fun vouch_for_loan(account: &signer, union_addr: address, borrower: address, amount: u64, interest_rate: u64)
    acquires CreditUnion, MemberAccount, Loan {
        let union = borrow_global<CreditUnion>(union_addr);
        let voucher = signer::address_of(account);
        assert!(vector::contains(&union.members, &voucher), E_NOT_MEMBER);
        assert!(interest_rate >= union.min_interest_rate && interest_rate <= union.max_interest_rate, E_INTEREST_RATE_OUT_OF_BOUNDS);

        let member_account = borrow_global_mut<MemberAccount>(voucher);
        assert!(member_account.balance >= amount, E_INSUFFICIENT_BALANCE);

        member_account.staked_amount = member_account.staked_amount + amount;
        member_account.balance = member_account.balance - amount;

        let loan = borrow_global_mut<Loan>(borrower);
        vector::push_back(&mut loan.vouchers, Voucher { voucher, amount, interest_rate });

        // Calculate average interest rate
        let total_amount = 0;
        let total_weighted_rate = 0;
        let i = 0;
        while (i < vector::length(&loan.vouchers)) {
            let voucher = vector::borrow(&loan.vouchers, i);
            total_amount = total_amount + voucher.amount;
            total_weighted_rate = total_weighted_rate + (voucher.amount * voucher.interest_rate);
            i = i + 1;
        };
        loan.interest_rate = total_weighted_rate / total_amount;

        // Set due date (e.g., 30 days from now)
        loan.due_date = timestamp::now_seconds() + 30 * 24 * 60 * 60;

        if (total_amount >= loan.amount) {
            // Loan is fully vouched, emit LoanApprovedEvent
            event::emit(LoanApprovedEvent { union: union_addr, borrower, amount: loan.amount, interest_rate: loan.interest_rate });
        }
    }
}
