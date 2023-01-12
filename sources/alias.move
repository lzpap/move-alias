// We start by defining the 'alias' module inside the 'stardust' package
module stardust::alias {
    // A bunch of imports are needed from the sui framework to be able to work with objects, transactions
    // Sui specific types.
    use std::option::{Self, Option}; // A move variable that might be empty
    use std::string::{Self, String}; // String type in the Sui framework
    use std::vector; // Vector is a list
    use sui::object::{Self, ID, UID}; // Objects must start with 'UID' privileged type
    use sui::transfer; // Package to handle transfering of objects
    use sui::tx_context::{Self, TxContext}; // Type to be able to access the current transaction context
    use sui::balance::{Self, Balance}; // Represents a balance of a coin
    use sui::coin::{Self, Coin}; // Represents a coin with balance
    use sui::object_bag::{Self, ObjectBag}; // A type that can hold a collection of objects (possible to nest obejcts within one another)
    use sui::event; // Events can be emitted during program execution. Events are not stored in the ledger state but help with indexing and discovery.

    // Error codes that our smart contract can return in case of failed execution
    const ENotGovernor: u64 = 0; // When a non-governor tries excercise governor functions
    const ENotStateController: u64 = 1; // When a non-state-controller tries to excercise state controller functions
    const ENotCurrentNonce: u64 = 2; // Nonce is needed to keep track of current controllers. Returned when a past controller tries to act.

    // Let's define the structure of an alias.
    // This struct becomes a Move type that can be used as an object, becuase:
    //  - it can be stored ('store keyword;)
    //  - it has the key ability, so it can be indexed on storage via its unique ID (UID)
    //
    // 'T' is a type parameter that essentially means that an alias can be instantiated with whatever coin type
    struct Alias<phantom T> has key, store {
        id: UID, // Globally unique identifier, determined upon creation
        base_token: Balance<T>, // iota/sui balance of an alias
        // Native token support not impelmented in this demo!
        native_tokens: Option<ObjectBag>, // (Optional)  A bag that can hold a collection of native token objects.
        state_index: u64, // Current state index of the alias
        state_metadata: vector<u8>, // State metadata of the alias
        // Foundry logic not implemented in this demo!
        foundry_counter: u64, // Number of foundries created
        sender: Option<address>, // (Optional) Last sender of the alias
        metadata: Option<vector<u8>>, // (Optional) metadata attached to the alias
        issuer: Option<address>, // (Optional) issuer of the alias
        immutable_metatada: Option<vector<u8>>, // (Optional) immutable metadata attached to the alias
        cap_nonce: u64, // Nonce that identifies the current state controller and governor
    }

    // How do we define the state controller and governor?
    // We will use the 'Capapility' pattern:
    //     - We essentially mint capability NFTs that give you the privilige to execute some function on the alias if you prove you own them.
    //     - The NFTs a standalone objects themselves, but we don't implement a transfer function for them so they are soulbound.
    //     - To set a new controller, we require passing in the old NFTs, we destroy them and mint new ones.

    // State controller capability
    struct StateCap has key, store {
        id: UID, // The capability object's unique ID
        ref_alias: ID, // Defines which alias this state capability controls
        nonce: u64, // identifies whether it's the current one
    }

    // Governor capability
    struct GovernorCap has key, store {
        id: UID,
        ref_alias: ID,
        nonce: u64,
    }

    // Event definitions that will be emmitted
    struct AliasCreated has copy, drop {
        // Notice that these structs don't have the key and store ability. So they can not be objects in the ledger.
        // Also, these structs can be copied or dropped during program execution.
        id: ID, // A non-privileged type for encoding the alias's object ID
        init_balance: u64 // Additional data that we want to encode in the event
    }

    struct AliasDestroyed has copy, drop {
        id: ID,
        last_balance: u64
    }

    // Let's write a function that can create an alias. It's an entry function, meaning it can be called directly in
    // a transaction (Move Call)
    //
    //  - 'T' is still the type parameter that defines the type of base token for the alias
    //  - We need to pass in an object of 'Coin' type, these coins will be put into the alias
    //  - Immutable metadata is also set at creation
    //  - TxContext is just a privileged type that gives us access to the context of the transaction at runtime
    public entry fun create_alias<T>(c: Coin<T>, immutable_metatada: vector<u8>, ctx: &mut TxContext) {
        // Creation of a new unique id. Under the hood, the id is derived from the transaction hash.
        let id = object::new(ctx);
        // 'id' is of type 'UID' which is not allowed to be copied in code, so we just extract its value with a native
        // function so we can refernce it in the capabilities.
        let alias_id = object::uid_to_inner(&id);
        
        // Instansitation of an Alias Struct that can act as an object.
        let a = Alias {
            id: id, // Must be if 'UID' type.
            base_token: coin::into_balance(c), // we destroy the passed in coin object and keep only its balance
            native_tokens: option::none<ObjectBag>(), // we don't have native tokens
            state_index: 0, // Start from 0
            state_metadata: vector::empty(), // Empty
            foundry_counter: 0, // Start from 0
            sender: option::none(), // Empty
            metadata: option::none(), // Empty
            issuer: option::some(tx_context::sender(ctx)), // We se the issuer to be the sender of the current transaction
            immutable_metatada: option::some(immutable_metatada), // We set the metadata
            cap_nonce: 0, // Nonce starts from zero too
        };

        // Event emittion. We create the event structs inline.
        event::emit(AliasCreated{id: object::uid_to_inner(&a.id), init_balance: balance::value<T>(&a.base_token)});

        // We make the alias object shared. A shared object doesn't have a single address owner but instead anyone can
        // included it in a transaction.
        transfer::share_object(a);
        
        // Creation of state controller and governor capabilities. At the same time, we send them to the sender of the
        // current transaction, that is, the issuer.

        // The state controller
        transfer::transfer(
            StateCap {
                id: object::new(ctx),
                ref_alias: alias_id,
                nonce: 0
            },
            tx_context::sender(ctx)
        );
        // The governor
        transfer::transfer(
            GovernorCap {
                id: object::new(ctx),
                ref_alias: alias_id,
                nonce: 0},
            tx_context::sender(ctx)
        );
    }

    // A bunch of utility functions to help working with our structs.
    // Important: These functions can only be called from within this package!
    // As a result, we lock what kind of operations are possible and what not. For example, there is no function to
    // update the immutable metadata so that operation can never be performed.
    // (note: it would be possible to make these functions:
    //  - public (library functions)
    //  - or 'friendly', meaning we could define modules on other packages that are allowed to call them)

    // Increment the state index field of an alias
    fun increment_state_index<T>(self: &mut Alias<T>) {
        self.state_index = self.state_index + 1;
    }

    // Increment the capability nonce field of the alias
    fun increment_cap_nonce<T>(self: &mut Alias<T>) {
        self.cap_nonce = self.cap_nonce + 1;
    }

    // Set a new state metadata on the alias
    fun set_state_metadata<T>(self: &mut Alias<T>, data: vector<u8>){
        self.state_metadata = data;
    }

    // Increment the foundry counter field of the alias
    fun increment_foundry_counter<T>(self: &mut Alias<T> ) {
        self.foundry_counter = self.foundry_counter + 1;
    }

    // Set the sender of an alias to be the sender of the current transaction
    fun set_sender<T>(self: &mut Alias<T>, ctx: &mut TxContext){
        self.sender = option::some(tx_context::sender(ctx)) ;
    }

    // Set the metadata field of the alias
    fun set_metadata<T>(self: &mut Alias<T>, data: vector<u8>) {
        self.metadata = option::some(data);
    }

    // Deposit a balance of a coin with type 'T' into the alias
    fun deposit<T>(self: &mut Alias<T>, c: Balance<T>) {
        balance::join(&mut self.base_token, c);
    }

    // Withdrae 'amount' of coins with type 'T' from the alias
    fun withdraw<T>(self: &mut Alias<T>, amount: u64): Balance<T> {
        balance::split(&mut self.base_token, amount)
    }
    
    // Given a governor cap and an alias, check if this is the current governor of the alias
    fun check_governor_cap<T>(g: &GovernorCap, self: &mut Alias<T>) {
        assert!(g.ref_alias == object::uid_to_inner(&self.id), ENotGovernor);
        assert!(g.nonce == self.cap_nonce, ENotCurrentNonce);
    }

    // Given a state controller cap and an alias, check if this is the current state controller of the alias
    fun check_state_cap<T>(s: &StateCap, self: &mut Alias<T>) {
        assert!(s.ref_alias == object::uid_to_inner(&self.id), ENotStateController);
        assert!(s.nonce == self.cap_nonce, ENotCurrentNonce);
    }

    // Public entry function do destroy a state controller capability. Needed to be able to clean it up once your capability
    // expired. If we don't define such a function inside this module, no one woudl be able to delete/throw away a capability
    // NFT.
    public entry fun destroy_state_cap(s: StateCap, _ctx: &mut TxContext) {
        // Since the cap was passed into the function by value, we can decompose it.
        // Once we decompose it, we can drop (forget) the values of individual fields.
        //
        // Note: the UID field ('id1') needs to be deleted with special API, the other field types have the 'drop' ability.
        let StateCap {
            id: id1,
            ref_alias: _,
            nonce: _,
        } = s;

        // Deletion of a variable with UID type.
        object::delete(id1);
        // At this point the NFT cease to exist and as a result of the transaction it is deleted from global storage.
    }

    // Public entry function to destroy a governor cap. Same as above.
    public entry fun destroy_governor_cap(g: GovernorCap, _ctx: &mut TxContext) {
        let GovernorCap {
            id: id1,
            ref_alias: _,
            nonce: _,
        } = g;

        object::delete(id1);
    }


    // Implementation of a governance state transition.
    // Such a transition can only change:
    //  - state controller,
    //  - gvernor,
    //  - metadata
    public entry fun governance_transition<T>(
        g: GovernorCap, // A governor cap must be passed in here
        self: &mut Alias<T>, // Along with the alias
        new_governor: address, // New governor address to set
        new_state_controller: address, // New state controller address to set
        new_metadata: vector<u8>, // New metadata to set
        ctx: &mut TxContext,
        ){
            //  only holder of the current governor cap can call this, otherwise fails
            check_governor_cap(&g, self);
            // destroy the governor cap
            // state cap we can't destroy here, but it's owner can call destroy_state_cap themselves in a separate tx. Due to the nonce, it won't work anymore.
            destroy_governor_cap(g, ctx);
            // increment cap nonce
            increment_cap_nonce(self);
            // set the new metadata
            set_metadata(self, new_metadata);

            // Let's mint the new capabilities and transfer them to the addresses passed in as arguments
            let alias_id = object::uid_to_inner(&self.id);
            transfer::transfer(
                // What to transfer?
                StateCap {
                    id: object::new(ctx),
                    ref_alias: alias_id,
                    nonce: self.cap_nonce
                },
                new_state_controller // where to transfer
            );
            transfer::transfer(
                // What to transfer?
                GovernorCap {
                    id: object::new(ctx),
                    ref_alias: alias_id,
                    nonce: self.cap_nonce
                },
                new_governor // where to transfer
            );
        }

    // Time to implement the state transition. So what does a state transition do when an alias is used in ISC (stardust)?
    //  - it takes a bunch of on-ledger reguests, consume them in the transaction
    //  - executes the requests one by one, generatting new L2 state and possible resulting payout/outputs
    //
    // We run into a problem with Sui though: An entry function can not take variable size inputs, so we can't just
    //  say "pass in a list of requests". Also, to be able to send something to an alias by it's UID (address), users
    // must posses access rights to it. Sui lacks the alias address unlock condition.
    //
    // Therefore, we will create another layer: the MemPool.
    //  - The Mempool is a shared object tighly coupled to the alias.
    //  - Users can put their requests in the MemPool to be processed by the ISC chain controlling the alias
    //  - Once enough requests are in the MemPool, the alias can state transition by referencing the single MemPool
    //    object that ocntains all the requests to be executed.
    //
    // Flowchart:
    // Step 1: Users send requests: !!!send_request() function!!!
    //
    // User A -> prepares Request A -> puts in in the Mempool
    // User B -> prepares Request B -> puts in in the Mempool
    // User C -> prepares Request C -> puts in in the Mempool
    //
    // Step 2: ISC committee executes requests on L2: !!!create_exec_result() function!!!
    //
    // ISC Committee looks at mempool, chooses which ones to execute, executes them on L2, saves their result in ExecutionResultPool
    //
    // Step 3: ISC committee settles the result of execution on L1, consuming the requests from mempool and sending out ExecutionResults
    //         !!!state_transition() function!!!
    //
    // (Alias, Mempool, ExecutionResultPool) -> state transitions ->
    //   -> (Updated Alias, Depleted Mempool, Depleted ExecutionResultPool, sent out RequestResult A, RequestResult B, RequestResult C)


    // First, we need to define the structs for requests, the mempool the request result and some utility structs.

    // An on-ledger request is essentially a Basic Output that holds tokens, has a sender and metadata
    struct OnLedgerRequest<phantom T> has store {
        base_token: Balance<T>,
        sender: address, // validated sender of the request
        calldata: vector<u8>, // command to L2, encoded in 'metadata feature' in stardust
    }

    // Am object that holds a list of to-be processed OnLedgerRequests
    struct MemPool<phantom T> has key, store {
        id: UID,
        ref_alias: ID,
        pool: vector<OnLedgerRequest<T>>,
    }

    // A request result is payout as a result of processing a request oin the L2 VM.
    struct RequestResult<phantom T> has key, store {
        id: UID,
        base_token: Balance<T>,
        request_id: String,
    }

    // A pure utility object that holds the results of processed requests from L2.
    // We need it to be able to tell the state transition function who to pay out to.
    // In a real world setting, the ISC committee would:
    //   - look at the MemPool
    //   - process the requests in them on L2, determining their results
    //   - put the results in the ResultPool
    //   - call the state_transition() function on L1 with the MemPool, Alias and ResultPool
    //   - The effect of the state_transition() function is that it initiates the sending of RequestResult's to recipients
    //     in the ResultPool
    struct ExecutionResultPool has key, store {
        id: UID,
        ref_alias: ID,
        pool: vector<ExecutionResult>,
    }

    // A pure utility struct that hold information on who to send out RequestResults.
    struct ExecutionResult has store, drop {
        payout: u64,
        //request_id: String,
        recipient: address,
    }

    // Entry function for user wallets to send requests to the MemPool
    public entry fun send_request<T>(c: Coin<T>, calldata: vector<u8>, target: &mut MemPool<T>, ctx: &mut TxContext){
        // Note that OnLedgerRequest doesn't need to appear as standalone object, it will be stored inside the
        // MemPool object. It is simply a struct that holds coins.
        let req = OnLedgerRequest<T> {
            base_token: coin::into_balance<T>(c),
            sender: tx_context::sender(ctx),
            calldata: calldata,
        };
        
        // Put the request in the mempool
        vector::push_back<OnLedgerRequest<T>>(&mut target.pool, req);
    }

    // Utility function to be called by ISC committee to create execution results.
    // - 'n' is the number of requests
    public entry fun create_exec_results<T>(s: StateCap, self: &mut Alias<T>, n: u64, a: address, ctx: &mut TxContext){
        // only holder of the current state cap can call this
        check_state_cap(&s, self);
        // Since state cap was passed in via value, we will just send it back tto where it came from
        transfer::transfer(s, tx_context::sender(ctx));

        // An empty list
        let results = vector::empty<ExecutionResult>();

        // Dummy result creation, we will just pay out 1000 coins as a result of any request
        let i = 0;
        while (i < n){
            i=i+1;
            vector::push_back(&mut results, ExecutionResult{payout: 10000, recipient: a});
        };

        // Send the ResultPool to ISC committee. Note, that we would send it to the alias address if Sui had such a feature.
        transfer::transfer(
            ExecutionResultPool { id: object::new(ctx), ref_alias: object::uid_to_inner(&self.id), pool: results }, tx_context::sender(ctx));
    }

    // State transition settles the results of processed requests on L1.
    public entry fun state_transition<T>(
        s: StateCap,
        self: &mut Alias<T>,
        mempool: &mut MemPool<T>, // contains the on-ledger requests
        out: ExecutionResultPool, // contains the result of those requests
        new_state: vector<u8>, // the new L2 state hash as a result of the processed requests
        ctx: &mut TxContext,
    ){
        // only holder of the current state cap can call this
        check_state_cap(&s, self);
        // since state cap was passed in by value, we need to send it back
        transfer::transfer(s, tx_context::sender(ctx));

       // Is this the correct ExecutionResultPool?
        assert!(out.ref_alias == object::uid_to_inner(&self.id), 10);

        // increment state index
        increment_state_index(self);

        // set new state hash
        set_state_metadata(self, new_state);

        // set the sender for the alias
        set_sender(self, ctx);

        // Book incoming on ledger requests (equivalent to consuming BasicOutputs that represent on-ledger requests)
        // the actual logic happens on L2, here we just imitate that all requests deposit their coins into the alias
        vector::reverse<OnLedgerRequest<T>>(&mut mempool.pool);

        while (!vector::is_empty<OnLedgerRequest<T>>(&mempool.pool)) {
            // The L2 VM would fetch this info and execute it on L2
            // We mimic that in create_exec_result() function
            let OnLedgerRequest {
                base_token: token,
                sender: _,
                calldata: _,
            } = vector::pop_back(&mut mempool.pool);

            // On L1 all we can do is deposit the tokens into the alias
            deposit(self, token);
        };

        // Settle request execution results
        // What is in the result is determined by L2 (ISC committee)? L1 is blind to it, that's why we need a list
        // of result in ExecutionResultPool

        // reverse the pool so we start with oldest first
        vector::reverse<ExecutionResult>(&mut out.pool);

        while (!vector::is_empty<ExecutionResult>(&out.pool)) {
            let result = vector::pop_back(&mut out.pool);

            // Send out RequestResults to users. Equivalent to creating a BasicOutput with the result in stardust.
            transfer::transfer(RequestResult{
                id: object::new(ctx),
                base_token: withdraw(self, result.payout),
                request_id: string::utf8(b"dummy"),
            }, result.recipient);
        };

        // Send back the empty result pool to ISC committee
        transfer::transfer(out, tx_context::sender(ctx));
    }
}