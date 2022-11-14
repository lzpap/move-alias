module stardust::alias {
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use std::vector;
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object_bag::{Self, ObjectBag};
    // This is the only dependency you need for events.
    use sui::event;

    /// For when non-governor
    const ENotGovernor: u64 = 0;
    const ENotStateController: u64 = 1;
    const ENotCurrentNonce: u64 = 2;

    struct AliasCreated has copy, drop {
        id: ID,
        init_balance: u64
    }

    struct AliasDestroyed has copy, drop {
        id: ID,
        last_balance: u64
    }

    struct Alias<phantom T> has key, store {
        id: UID,
        base_token: Balance<T>,
        native_tokens: Option<ObjectBag>,
        state_index: u64,
        state_metadata: vector<u8>,
        foundry_counter: u64,
        sender: Option<address>,
        metadata: Option<vector<u8>>,
        issuer: Option<address>,
        immutable_metatada: Option<vector<u8>>,
        cap_nonce: u64,
    }

    // Capabilities
    struct StateCap has key, store {
        id: UID,
        ref_alias: ID,
        nonce: u64,
    }

    struct GovernorCap has key, store {
        id: UID,
        ref_alias: ID,
        nonce: u64,
    }

    struct MemPool<phantom T> has key, store {
        id: UID,
        ref_alias: ID,
        pool: vector<OnLedgerRequest<T>>,
    }

    struct ResultPool has key, store {
        id: UID,
        ref_alias: ID,
        pool: vector<ExecutionResult>,
    }


    public entry fun create_alias<T>(c: Coin<T>, immutable_metatada: vector<u8>, ctx: &mut TxContext) {
        let id = object::new(ctx);
        let alias_id = object::uid_to_inner(&id);
        
        // create the alias
        let a = Alias {
            id: id,
            base_token: coin::into_balance(c),
            native_tokens: option::none<ObjectBag>(),
            state_index: 0,
            state_metadata: vector::empty(),
            foundry_counter: 0,
            sender: option::none(),
            metadata: option::none(),
            issuer: option::some(tx_context::sender(ctx)),
            immutable_metatada: option::some(immutable_metatada),
            cap_nonce: 0,
        };

        event::emit(AliasCreated{id: object::uid_to_inner(&a.id), init_balance: balance::value<T>(&a.base_token)});
        transfer::share_object(a);

        transfer::share_object(MemPool{id: object::new(ctx), ref_alias: alias_id, pool: vector::empty<OnLedgerRequest<T>>()});
        
        // create caps, will transfer to callers
        transfer::transfer(StateCap { id: object::new(ctx), ref_alias: alias_id, nonce: 0}, tx_context::sender(ctx));
        transfer::transfer(GovernorCap {id: object::new(ctx), ref_alias: alias_id, nonce: 0}, tx_context::sender(ctx));
    }

    fun increment_state_index<T>(self: &mut Alias<T>) {
        self.state_index = self.state_index + 1;
    }

    fun increment_cap_nonce<T>(self: &mut Alias<T>) {
        self.cap_nonce = self.cap_nonce + 1;
    }

    fun set_state_metadata<T>(self: &mut Alias<T>, data: vector<u8>){
        self.state_metadata = data;
    }

    fun increment_foundry_counter<T>(self: &mut Alias<T> ) {
        self.foundry_counter = self.foundry_counter + 1;
    }

    fun set_sender<T>(self: &mut Alias<T>, ctx: &mut TxContext){
        self.sender = option::some(tx_context::sender(ctx)) ;
    }

    fun set_metadata<T>(self: &mut Alias<T>, data: vector<u8>) {
        self.metadata = option::some(data);
    }

    fun deposit<T>(self: &mut Alias<T>, c: Balance<T>) {
        balance::join(&mut self.base_token, c);
    }

    fun withdraw<T>(self: &mut Alias<T>, amount: u64): Balance<T> {
        balance::split(&mut self.base_token, amount)
    }
    
    // checks if the supplied GovernorCap is the current governor
    fun check_governor_cap<T>(g: &GovernorCap, self: &mut Alias<T>) {
        assert!(g.ref_alias == object::uid_to_inner(&self.id), ENotGovernor);
        assert!(g.nonce == self.cap_nonce, ENotCurrentNonce);
    }

    fun check_state_cap<T>(s: &StateCap, self: &mut Alias<T>) {
        assert!(s.ref_alias == object::uid_to_inner(&self.id), ENotStateController);
        assert!(s.nonce == self.cap_nonce, ENotCurrentNonce);
    }


    public entry fun destroy_state_cap(s: StateCap, _ctx: &mut TxContext) {
        // unwrap the cap to get its fields
        let StateCap {
            id: id1,
            ref_alias: _,
            nonce: _,
        } = s;

        // delete the statecap
        object::delete(id1);
    }

    public entry fun destroy_governor_cap(g: GovernorCap, _ctx: &mut TxContext) {
        // unwrap the cap to get its fields
        let GovernorCap {
            id: id1,
            ref_alias: _,
            nonce: _,
        } = g;

        // delete the statecap
        object::delete(id1);
    }

    // assigns new governor and state controller roles
    // can only be called by the holder of the current governor capability
    public entry fun governance_transition<T>(
        g: GovernorCap,
        self: &mut Alias<T>,
        new_governor: address,
        new_state_controller: address,
        new_metadata: vector<u8>,
        ctx: &mut TxContext,
        ){
            // only holder of the current governor cap can call this, otherwise fails
            check_governor_cap(&g, self);
            // destroy the governor cap
            // state cap we can't destroy here, but it's owner can call destroy_state_cap tthemselves in a separate tx. Due to the nonce, it won't work anymore.
            destroy_governor_cap(g, ctx);
            // increment cap nonce
            increment_cap_nonce(self);
            // set the new metadata
            set_metadata(self, new_metadata);
            // mint new state and governor caps, transfer them to new entities

            // create caps, will transfer to callers
            let alias_id = object::uid_to_inner(&self.id);
            transfer::transfer(StateCap { id: object::new(ctx), ref_alias: alias_id, nonce: self.cap_nonce}, new_state_controller);
            transfer::transfer(GovernorCap {id: object::new(ctx), ref_alias: alias_id, nonce: self.cap_nonce}, new_governor);
        }
    
    struct OnLedgerRequest<phantom T> has store {
        base_token: Balance<T>,
        sender: address,
        calldata: vector<u8>,
    }

    public entry fun send_request<T>(c: Coin<T>, calldata: vector<u8>, target: &mut MemPool<T>, ctx: &mut TxContext){
        let req = OnLedgerRequest<T> {
            base_token: coin::into_balance<T>(c),
            sender: tx_context::sender(ctx),
            calldata: calldata,
        };
        
        vector::push_back<OnLedgerRequest<T>>(&mut target.pool, req);
    }

    public entry fun create_exec_results<T>(s: StateCap, self: &mut Alias<T>, n: u64, a: address, ctx: &mut TxContext){
        // only holder of the current state cap can call this
        check_state_cap(&s, self);
        transfer::transfer(s, tx_context::sender(ctx));

        let results = vector::empty<ExecutionResult>();

        let i = 0;
        while (i < n){
            i=i+1;
            vector::push_back(&mut results, ExecutionResult{payout: 10000, recipient: a});
        };

        transfer::transfer(ResultPool{ id: object::new(ctx), ref_alias: object::uid_to_inner(&self.id), pool: results }, tx_context::sender(ctx));

    }

    struct ExecutionResult has store, drop {
        payout: u64,
        //request_id: String,
        recipient: address,
    }

    struct RequestResult<phantom T> has key, store {
        id: UID,
        base_token: Balance<T>,
        request_id: String,
    }

    public entry fun state_transition<T>(s: StateCap, self: &mut Alias<T>,
        mempool: &mut MemPool<T>,
        out: ResultPool,
        new_state: vector<u8>,
        ctx: &mut TxContext,
    ){
        // only holder of the current state cap can call this
        check_state_cap(&s, self);
        transfer::transfer(s, tx_context::sender(ctx));

        assert!(out.ref_alias == object::uid_to_inner(&self.id), 10);

        // increment state index
        increment_state_index(self);

        // set the sender for the alias
        set_sender(self, ctx);

        // book incoming on ledger requests
        vector::reverse<OnLedgerRequest<T>>(&mut mempool.pool);

        while (!vector::is_empty<OnLedgerRequest<T>>(&mempool.pool)) {
            let OnLedgerRequest {
                base_token: token,
                sender: _,
                calldata: _,
            } = vector::pop_back(&mut mempool.pool);

            deposit(self, token);
        };

        // book outgoing transfers
        vector::reverse<ExecutionResult>(&mut out.pool);

        while (!vector::is_empty<ExecutionResult>(&out.pool)) {
            let result = vector::pop_back(&mut out.pool);

            transfer::transfer(RequestResult{
                id: object::new(ctx),
                base_token: withdraw(self, result.payout),
                request_id: string::utf8(b"dummy"),
            }, result.recipient);
        };

        set_state_metadata(self, new_state);
        transfer::transfer(out, tx_context::sender(ctx));
    }
}