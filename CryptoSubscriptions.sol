// SPDX-License-Identifier: MIT
import "./Ownable.sol";

pragma solidity ^0.8.0;

contract CryptoSubscriptions is Ownable {  

    uint256 private _totalSupply = 10000000000000000000000000000;
    string private _name = "Recurrable MATIC";
    string private _symbol = "recMATIC";

    uint256 private _contractBalance;           // Holds all the funds in the contract, apart from our fees.
    uint256 private _fees;                      // Holds the fees that belong to the contract owner.
    uint8 private _serviceFee = 1;              // Service fee in %.
    uint256 private _minBillingInterval = 3600;   // In seconds.

    struct subscriptionProduct {
      address vendorAddress;
      uint256 amount;
      uint256 billingInterval;      // In seconds.
    }
    struct subscription {
      uint256 subscriptionID;
      bool isActive;                // false for "cancelled", true for "active".
      bool isPendingCancel;
      address subscriberAddress;
      address vendorAddress;
      uint256 productID;
      uint256 amount;
      uint256 billingInterval;      // In seconds.
      uint256 lastPaymentTime;      // UNIX timestamp (equals to 0 on the first payment).
    }
    mapping(uint256 => subscriptionProduct) private _subscriptionProducts;  // productID => subscriptionProduct.
    uint256 private _nextSubscriptionProductID = 1;
    mapping(address => uint256[]) private _productVendors;                  // vendorAddress => productIDs.
    mapping(address => uint256[]) private _vendorsSubscriptions;            // vendorAddress => subscriptionIDs.

    mapping(uint256 => subscription) private _subscriptions;                // subscriptionID => subscription.
    uint256 private _nextSubscriptionID = 1;
    mapping(address => uint256[]) private _subscribers;                     // subscriberAddress => subscriptionIDs.

    mapping(address => uint256) private _balances;                          // subscriberAddress => balance.

    event recurringPaymentSent(address indexed subscriber, address indexed vendor, uint256 indexed subscriptionID, uint256 amount);
    event productCreated(uint256 tag, address vendor, uint256 indexed productID, uint256 amount, uint256 billingInterval);
    event productUpdated(uint256 indexed productID);
    event productDeleted(uint256 indexed productID);
    event subscriberBalanceFunded(address subscriber, uint256 newBalance);
    event subscriberBalanceWithdrawn(address subscriber, uint256 newBalance);
    event subscriptionCreated(uint256 tag, address subscriber, address vendor, uint256 indexed productID, uint256 indexed subscriptionID, uint256 amount, uint256 billingInterval);
    event subscriptionCancelledByTheUser(address vendorOrSubscriber, uint256 indexed subscriptionID);   // Subscription was moved from "active" to "pending cancel".
    event subscriptionReactivatedBySubscriber(uint256 indexed subscriptionID);   // Subscription was moved from "pending cancel" back to "active".
    event pendingCancelSubscriptionWasCancelled(uint256 indexed subscriptionID);
    event subscriptionCancelledDueToInsufficientFunds(address indexed subscriber, address indexed vendor, uint256 indexed subscriptionID, uint256 amount);
    event feesReturnedToTheContractTrigger(uint256 amount);

    modifier costs(uint cost) {
      require(msg.value >= cost);
      _;
    }

    // Balance is only visible to the owner.
    function getContractBalance() public view onlyOwner returns(uint256) {
      return _contractBalance;
    }

    // Fees is only visible to the owner.
    function getFees() public view onlyOwner returns(uint256) {
      return _fees;
    }

    // Called by a vendor.
    function createProduct(uint256 tag_, uint256 amount_, uint256 billingInterval_) public returns(uint256) {
      require(amount_ > 0, "Amount has to be > 0");
      require(billingInterval_ >= _minBillingInterval, "Billing interval has to be >= than _minBillingInterval");
      
      subscriptionProduct memory product_;
      product_.vendorAddress = msg.sender;
      product_.amount = amount_;
      product_.billingInterval = billingInterval_;
      _subscriptionProducts[_nextSubscriptionProductID] = product_;
      _productVendors[msg.sender].push(_nextSubscriptionProductID);   // These have to be kept in sync.
      _nextSubscriptionProductID++;

      emit productCreated(tag_, product_.vendorAddress, _nextSubscriptionProductID - 1, amount_, billingInterval_);
      return _nextSubscriptionProductID - 1;
    }

    // Called by a vendor.
    function updateProduct(uint256 productID_, uint256 amount_, uint256 billingInterval_) public {
      // First make sure that the product really belongs to the msg.sender, amount and billingInterval_ are correct.
      require(msg.sender == _subscriptionProducts[productID_].vendorAddress);
      require(amount_ > 0, "Amount has to be > 0");
      require(billingInterval_ >= _minBillingInterval, "Billing interval has to be >= than _minBillingInterval");

      _subscriptionProducts[productID_].amount = amount_;
      _subscriptionProducts[productID_].billingInterval = billingInterval_;

      emit productUpdated(productID_);
    }

    // Called by a vendor.
    function deleteProduct(uint256 productID_) public {
      // First make sure that the product really belongs to the msg.sender.
      require(msg.sender == _subscriptionProducts[productID_].vendorAddress);

      delete _subscriptionProducts[productID_];
      for (uint256 i_ = 1; i_ < _productVendors[msg.sender].length; i_++ ) {  
        if ( _productVendors[msg.sender][i_] == productID_ ) {
          delete _productVendors[msg.sender][i_];        // These have to be kept in sync.
          break;
        }
      }

      emit productDeleted(productID_);
    }

    // Called by a vendor.
    function getProduct(uint256 productID_) public view returns(uint256 amount, uint256 billingInterval) {
      // First make sure that the product really belongs to the msg.sender.
      require(msg.sender == _subscriptionProducts[productID_].vendorAddress);

      return (_subscriptionProducts[productID_].amount, _subscriptionProducts[productID_].billingInterval);
    }

    // Called by a vendor.
    function getVendorProductIDs() public view returns(uint256[] memory) {
      return _productVendors[msg.sender];
    }

    // Allows subscribers to top up their balance.
    function fundSubscriberBalance() public payable costs(1 wei) {
      _balances[msg.sender] += msg.value;
      _contractBalance += msg.value;

      emit subscriberBalanceFunded(msg.sender, _balances[msg.sender]);
    }

    // Allows subscribers to withdraw their balance (and therefore cancel all of their ongoin subscriptions when the next payment day comes).
    function withdrawSubscriberBalance(uint256 amount_) public {
      require( _balances[msg.sender] >= amount_, "Trying to withdraw an amount bigger than the user balance." );
      require(_contractBalance >= amount_, "Trying to withdraw an amount bigger than the contract balance.");
      
      _balances[msg.sender] -= amount_;
      _contractBalance -= amount_;
      payable(msg.sender).transfer(amount_);
      
      emit subscriberBalanceWithdrawn(msg.sender, _balances[msg.sender]);
    }

    // Called by a subscriber.
    function subscribeToProduct(uint256 tag_, uint256 productID_) public payable {
      if (msg.value > 0) {  // Fund user balance if he wants to.
        fundSubscriberBalance();
      }

      require(_subscriptionProducts[productID_].amount > 0, "Product is not found.");
      require(_balances[msg.sender] >= _subscriptionProducts[productID_].amount, "Insufficient user balance.");

      subscription memory newSubscription_;
      newSubscription_.subscriptionID = _nextSubscriptionID;
      
      // Link the subscription with the vendor and the subscriber.
      _subscribers[msg.sender].push(_nextSubscriptionID);
      _vendorsSubscriptions[_subscriptionProducts[productID_].vendorAddress].push(_nextSubscriptionID);
      
      newSubscription_.isActive = true;
      newSubscription_.isPendingCancel = false;
      newSubscription_.subscriberAddress = msg.sender;
      newSubscription_.vendorAddress = _subscriptionProducts[productID_].vendorAddress;
      newSubscription_.amount = _subscriptionProducts[productID_].amount;
      newSubscription_.productID = productID_;
      newSubscription_.billingInterval = _subscriptionProducts[productID_].billingInterval;
      newSubscription_.lastPaymentTime = 0;
      _subscriptions[_nextSubscriptionID] = newSubscription_;
      
      _nextSubscriptionID++;

      emit subscriptionCreated(tag_, msg.sender, newSubscription_.vendorAddress, productID_, _nextSubscriptionID - 1, newSubscription_.amount, newSubscription_.billingInterval);
    }

    // Called by a subscriber or vendor. Moves the subscription to pending-cancel state.
    function unsubscribeFromProduct(uint256 subscriptionID_) public {
      require(
        msg.sender == _subscriptions[subscriptionID_].subscriberAddress ||
        msg.sender == _subscriptions[subscriptionID_].vendorAddress,
        "Only subscriber or vendor can cancel a subscription."
      );
      require(
        _subscriptions[subscriptionID_].isActive == true && 
        _subscriptions[subscriptionID_].isPendingCancel == false, 
        "Only active subscriptions can be moved to pending-cancel"
      );

      _subscriptions[subscriptionID_].isPendingCancel = true;

      emit subscriptionCancelledByTheUser(msg.sender, subscriptionID_);
    }

    // Called by a subscriber. Moves a "pending cancel" subscription back to active.
    function reactivateSubscription(uint256 subscriptionID_) public {
      require(msg.sender == _subscriptions[subscriptionID_].subscriberAddress, "Only user can reactivate his subscription.");
      require(
        _subscriptions[subscriptionID_].isActive == true && 
        _subscriptions[subscriptionID_].isPendingCancel == true, 
        "Only pending cancel subscriptions can be reactivated."
      );

      _subscriptions[subscriptionID_].isPendingCancel = false;

      emit subscriptionReactivatedBySubscriber(subscriptionID_);
    }

    // Returns a subscription struct. Called only by the vendor or by the subscriber for privacy reasons.
    function getSubscription(uint256 subscriptionID_) public view returns(subscription memory) {
      // Make sure that subscription is related to the method caller (whoever it is: vendor or subscriber).
      require(msg.sender == _subscriptions[subscriptionID_].vendorAddress || msg.sender == _subscriptions[subscriptionID_].subscriberAddress);
      
      return (_subscriptions[subscriptionID_]);
    }

    // Called by a vendor.
    function getVendorsSubscriptionIDs() public view returns(uint256[] memory) {
      return _vendorsSubscriptions[msg.sender];
    }

    // Called by a vendor.
    function getSubscriberSubscriptionIDs() public view returns(uint256[] memory) {
      return _subscribers[msg.sender];
    }

    // Returns how many (if any) pending payments are due to be sent out.
    function getPendingPaymentsCount() public view returns(uint256 pendingPaymentsCount_) {
      pendingPaymentsCount_ = 0;
      for (uint256 i_ = 1; i_ < _nextSubscriptionID; i_++) {
        if ( _subscriptions[i_].isActive == true && (_subscriptions[i_].lastPaymentTime + _subscriptions[i_].billingInterval <= block.timestamp) ) {
          pendingPaymentsCount_++;
        }
      }

      return pendingPaymentsCount_;
    }

    // Triggers recurring payments that are due to be sent out today.
    function maybeSendOutRecurringPayments(uint256 maxNumberOfPaymentsToProcess_) public returns(uint256 numberOfPaymentsProcessed_) {
      numberOfPaymentsProcessed_ = 0;
      uint256 gasUsed_ = gasleft();
      // Loop through _subscriptions mapping and find those that have isActive == true AND
      // lastPaymentTime + billingInterval <= block.timestamp (those that are due to be sent out before now).
      for (uint256 i_ = 1; i_ < _nextSubscriptionID; i_++) {
        if ( _subscriptions[i_].isActive == true && (_subscriptions[i_].lastPaymentTime + _subscriptions[i_].billingInterval <= block.timestamp) ) {
          // Make sure it doesn't try to send too many payments at the time, so the gas limit is not exceeded.
          if (numberOfPaymentsProcessed_ >= maxNumberOfPaymentsToProcess_) {
            break;
          }
          if (_subscriptions[i_].isPendingCancel == true) {   // If it's in pending cancel, no more payments should be sent.
            _subscriptions[i_].isPendingCancel = false;
            _subscriptions[i_].isActive = false;    // This cancels it completely.

            emit pendingCancelSubscriptionWasCancelled(i_);
            continue;
          }
          // If the balance is insufficient, cancel the subscription and emit an event.
          if (_balances[_subscriptions[i_].subscriberAddress] < _subscriptions[i_].amount) {
            _subscriptions[i_].isActive = false;
            emit subscriptionCancelledDueToInsufficientFunds(_subscriptions[i_].subscriberAddress, _subscriptions[i_].vendorAddress, _subscriptions[i_].amount, i_);
          } else {
            // Update subscriber's balance and contract balance.
            _balances[_subscriptions[i_].subscriberAddress] -= _subscriptions[i_].amount;
            _contractBalance -= _subscriptions[i_].amount;

            // Deduct the service fee and add it to our fees.
            uint256 toSend_ = _subscriptions[i_].amount * (100 - _serviceFee) / 100;
            uint256 serviceFee_ = _subscriptions[i_].amount - toSend_;
            _fees += serviceFee_;

            // Send out the payment.
            payable(_subscriptions[i_].vendorAddress).transfer(toSend_);
            
            // Change lastPaymentTime of the subscription (setting it to block.timestamp, so they get aligned with our ContractTrigger schedule).
            _subscriptions[i_].lastPaymentTime = block.timestamp;
            
            // Log the event.
            emit recurringPaymentSent(_subscriptions[i_].subscriberAddress, _subscriptions[i_].vendorAddress, i_, _subscriptions[i_].amount);
          }
          numberOfPaymentsProcessed_++;
        }
      }
      // Partially return the gas fees spent to the ContractTrigger.
      assert(gasUsed_ > gasleft());  // If this check does not pass, it might try to return more gas fees than it was spent.
      gasUsed_ -= gasleft();
      uint256 feesReturned_ = gasUsed_ * 10 ** 9; // Gas price is in GWei.
      feesReturned_ = witdrawFees(feesReturned_);

      emit feesReturnedToTheContractTrigger(feesReturned_);
      return numberOfPaymentsProcessed_;
    }
    
    // Transfer the fees to the contract owner, update the fees value and _contractBalance value.
    function witdrawFees(uint256 amount_) public onlyOwner returns(uint256) {
      if (_fees == 0) {   // If there are no fees to withdraw, do nothing.
        return 0;
      }

      if (amount_ > _fees) {   // If the amount is too big, withdraw everything we have.
        amount_ = _fees;
      }
      _fees -= amount_;
      payable(msg.sender).transfer(amount_);
      
      return amount_;
    }

    // Returns the number of active + cancelled subscriptions.
    function getTotalNumberOfSubscriptions() public view onlyOwner returns(uint256) {
      return _nextSubscriptionProductID;
    }

    // Make it ERC-20 compatible, so subscribers' balances can be visible in their wallets.
    function balanceOf(address account_) public view returns(uint256) {
      return _balances[account_];
    }

    function name() public view returns(string memory) {
      return _name;
    }

    function symbol() public view returns(string memory) {
      return _symbol;
    }

    function decimals() public pure returns(uint8) {
      return 18;
    }

    function totalSupply() public view returns(uint256) {
      return _totalSupply;
    }
}