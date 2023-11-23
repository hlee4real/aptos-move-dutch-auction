module admin::dutch_auction_nft {
    use std::string::String;
    use std::signer;
    use std::option::{Self, Option};

    use aptos_framework::coin;
    use aptos_framework::timestamp::now_seconds;
    use aptos_framework::event;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::account;

    use aptos_token::token::{Self, TokenId, Token};
    use aptos_std::table::Table;
    use aptos_std::table;


    const EAUCTION_NOT_STARTED: u64 = 1;
    const EAUCTION_ENDED: u64 = 2;
    const EBUY_AMOUNT_TOO_LOW: u64 = 3;
    const ESTARTING_PRICE_HIGHER_THAN_RESERVE_PRICE: u64 = 4;
    const EEND_TIME_BEFORE_START_TIME: u64 = 5;
    const ENOT_VALID_OWNER: u64 = 6;

    #[event]
    struct SoldToken has drop, store {
        buyer: address,
        price: u64,
        token_collection_name: String,
        token_name: String,
    }

    struct TokenCap has key {
        cap: SignerCapability,
    }

    struct DutchAuctions<phantom CoinType> has key {
        auctions: Table<String, DutchAuction<CoinType>>,
    }

    struct DutchAuction<phantom CoinType> has store , key{
        seller: address,
        dutch_auction_name: String,
        token_name: String,
        collection_name: String,
        id: TokenId,
        starting_price: u64,
        start_at: u64,
        end_at: u64,
        royalty_payee: address,
        royalty_numerator: u64,
        royalty_denominator: u64,
        locked_token: Option<Token>,
        discount_rate: u64
    }

    public entry fun init<CoinType>(sender: &signer) {
        let sender_addr = signer::address_of(sender);
        let (dutch_auction_signer, dutch_auction_cap) = account::create_resource_account(sender, x"01");
        let signer_address = signer::address_of(&dutch_auction_signer);
        assert!(sender_addr == @admin, ENOT_VALID_OWNER);
        if (!exists<DutchAuctions<CoinType>>(signer_address)) {
            move_to(&dutch_auction_signer, DutchAuctions { auctions: table::new<String, DutchAuction<CoinType>>() });
        };

        if (!exists<TokenCap>(@admin)) {
            move_to(sender, TokenCap { cap: dutch_auction_cap });
        };
    }

    public entry fun new_dutch_auction<CoinType>(seller: &signer,dutch_auction_name: String, creator: address, collection_name: String, token_name: String, property_version: u64, starting_price: u64, end_at: u64, discount_rate: u64) acquires DutchAuctions, TokenCap {
        let seller_addr = signer::address_of(seller);
        let start_at = now_seconds();

        assert!(end_at > start_at, EEND_TIME_BEFORE_START_TIME);
        assert!(starting_price > 0, ESTARTING_PRICE_HIGHER_THAN_RESERVE_PRICE);

        let dutch_auction_cap = &borrow_global<TokenCap>(@admin).cap;
        let dutch_auction_signer = &account::create_signer_with_capability(dutch_auction_cap);
        let signer_address = signer::address_of(dutch_auction_signer);

        let token_id = token::create_token_id_raw(creator, collection_name, token_name, property_version);

        let royalty = token::get_royalty(token_id);
        let royalty_payee = token::get_royalty_payee(&royalty);
        let royalty_numerator = token::get_royalty_numerator(&royalty);
        let royalty_denominator = token::get_royalty_denominator(&royalty);

        let token = token::withdraw_token(seller, token_id, 1);

        let dutch_auction = DutchAuction {
            seller: seller_addr,
            dutch_auction_name: dutch_auction_name,
            token_name: token_name,
            collection_name: collection_name,
            id: token_id,
            starting_price: starting_price,
            start_at: start_at,
            end_at: end_at,
            royalty_payee: royalty_payee,
            royalty_numerator: royalty_numerator,
            royalty_denominator: royalty_denominator,
            locked_token: option::some(token),
            discount_rate: discount_rate
        };

        let auctions = &mut borrow_global_mut<DutchAuctions<CoinType>>(signer_address).auctions;
        table::add(auctions, dutch_auction_name, dutch_auction);
    }

    public fun get_price(starting_price: u64, discount_rate: u64, start_at: u64) : u64{
        let time_elapsed = now_seconds() - start_at;
        let discount = discount_rate * time_elapsed;
        starting_price - discount
    }

    public entry fun buy_token<CoinType>(buyer: &signer, collection_name: String, token_name: String, property_version: u64, dutch_auction_name: String) acquires DutchAuctions, TokenCap {
        let buyer_addr = signer::address_of(buyer);        
        let dutch_auction_cap = &borrow_global<TokenCap>(@admin).cap;
        let dutch_auction_signer = &account::create_signer_with_capability(dutch_auction_cap);
        let dutch_auction_addr = signer::address_of(dutch_auction_signer);

        let dutch_auctions = borrow_global_mut<DutchAuctions<CoinType>>(dutch_auction_addr);
        let auctions = &mut dutch_auctions.auctions;
        let dutch_auction = table::borrow_mut(auctions, dutch_auction_name);
        let seller = dutch_auction.seller;
        let token_id = token::create_token_id_raw(dutch_auction.seller, dutch_auction.collection_name, dutch_auction.token_name, property_version);


        assert!(seller != buyer_addr, ENOT_VALID_OWNER);
        assert!(dutch_auction.start_at <= now_seconds(), EAUCTION_NOT_STARTED);
        assert!(dutch_auction.end_at >= now_seconds(), EAUCTION_ENDED);

        let price = get_price(dutch_auction.starting_price, dutch_auction.discount_rate, dutch_auction.start_at);
        assert!(price > 0, EBUY_AMOUNT_TOO_LOW);

        let royalty = token::get_royalty(token_id);
        let royalty_payee = token::get_royalty_payee(&royalty);
        let royalty_numerator = token::get_royalty_numerator(&royalty);
        let royalty_denominator = token::get_royalty_denominator(&royalty);

        let _fee_royalty: u64 = 0;

        if (royalty_denominator == 0){
            _fee_royalty = 0;
        } else {
            _fee_royalty = royalty_numerator * price / royalty_denominator;
        };

        if (_fee_royalty > 0) {
            coin::transfer<CoinType>(buyer, royalty_payee, _fee_royalty);
        };

        let sub_amount = price - _fee_royalty;

        // transfer coin to seller
        coin::transfer<CoinType>(buyer, seller, sub_amount);

        let token = option::extract(&mut dutch_auction.locked_token);
        token::deposit_token(buyer, token);

        let event = SoldToken {
            buyer: buyer_addr,
            price: sub_amount,
            token_collection_name: collection_name,
            token_name: token_name,
        };

        event::emit(event);

        let DutchAuction {seller: _, dutch_auction_name: _, token_name: _, collection_name: _, id: _, starting_price: _, start_at: _, end_at: _, royalty_payee: _, royalty_numerator: _, royalty_denominator: _, locked_token, discount_rate: _} = table::remove(auctions, dutch_auction_name);
        option::destroy_none(locked_token);
    }

    public entry fun cancel_auction_and_claim<CoinType>(seller: &signer, dutch_auction_name: String) acquires DutchAuctions, TokenCap{
        let seller_addr = signer::address_of(seller);
        let dutch_auction_cap = &borrow_global<TokenCap>(@admin).cap;
        let dutch_auction_signer = &account::create_signer_with_capability(dutch_auction_cap);
        let dutch_auction_addr = signer::address_of(dutch_auction_signer);

        let dutch_auctions = borrow_global_mut<DutchAuctions<CoinType>>(dutch_auction_addr);
        let auctions = &mut dutch_auctions.auctions;
        let dutch_auction = table::borrow_mut(auctions, dutch_auction_name);

        assert!(dutch_auction.seller == seller_addr, ENOT_VALID_OWNER);

        let token = option::extract(&mut dutch_auction.locked_token);
        token::deposit_token(seller, token);

        let DutchAuction {seller: _, dutch_auction_name: _, token_name: _, collection_name: _, id: _, starting_price: _, start_at: _, end_at: _, royalty_payee: _, royalty_numerator: _, royalty_denominator: _, locked_token, discount_rate: _} = table::remove(auctions, dutch_auction_name);
        option::destroy_none(locked_token);
    }
}