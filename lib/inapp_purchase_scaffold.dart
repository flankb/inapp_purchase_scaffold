library inapp_purchase_scaffold;

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

class InheritedPurchaserBlocProvider extends InheritedWidget {
  final Widget child;
  final PurchaserBloc bloc;

  InheritedPurchaserBlocProvider(
      {Key key, @required this.child, @required this.bloc})
      : super(key: key, child: child);

  static PurchaserBloc of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<InheritedPurchaserBlocProvider>()
        .bloc;
  }

  @override
  bool updateShouldNotify(InheritedWidget oldWidget) {
    return true;
  }
}

abstract class BasePurchaseBloc {
  void dispose();
}

class PurchaseCompletedState {
  final List<String> notFoundIds;
  final Map<String, ProductDetails> products;
  final Map<String, PurchaseDetails> purchases;
  final Map<String, String> productErrors;
  final List<String> consumables;
  final bool isAvailable;
  @deprecated
  final bool purchasePending;
  final bool loading;
  final String serviceError;

  factory PurchaseCompletedState.empty() {
    return PurchaseCompletedState(
      notFoundIds: [],
      products: {},
      purchases: {},
      consumables: [],
      isAvailable: false,
      purchasePending: false,
      loading: false,
      serviceError: null,
      productErrors: {},
    );
  }

  PurchaseCompletedState({
    @required this.notFoundIds,
    @required this.products,
    @required this.purchases,
    @required this.productErrors,
    @required this.consumables,
    @required this.isAvailable,
    @required this.purchasePending,
    @required this.loading,
    @required this.serviceError,
  });

  PurchaseCompletedState success() {
    return copyWith(serviceError: null, isAvailable: true, productErrors: {});
  }

  PurchaseCompletedState copyWith({
    List<String> notFoundIds,
    Map<String, ProductDetails> products,
    Map<String, PurchaseDetails> purchases,
    Map<String, String> productErrors,
    List<String> consumables,
    bool isAvailable,
    bool purchasePending,
    bool loading,
    String serviceError,
  }) {
    return new PurchaseCompletedState(
      notFoundIds: notFoundIds ?? this.notFoundIds,
      products: products ?? this.products,
      purchases: purchases ?? this.purchases,
      consumables: consumables ?? this.consumables,
      isAvailable: isAvailable ?? this.isAvailable,
      purchasePending: purchasePending ?? this.purchasePending,
      loading: loading ?? this.loading,
      serviceError: serviceError ?? this.serviceError,
      productErrors: productErrors ?? this.productErrors,
    );
  }

  bool productIsPending(String productId) {
    if (!purchases.containsKey(productId)) {
      return false;
    }

    return purchases[productId].status == PurchaseStatus.pending;
  }

  bool productIsAcknowledged(String productId) {
    if (!purchases.containsKey(productId)) {
      return false;
    }

    final pd = purchases[productId];

    if (Platform.isAndroid) {
      return (pd.status == PurchaseStatus.purchased &&
          pd.billingClientPurchase.isAcknowledged);
    }

    return (pd.status == PurchaseStatus.purchased);
  }

  @override
  String toString() {
    final purchasesStr = purchases.values
        .map((value) =>
            value.productID.toString() +
            ": " +
            value.status.toString() +
            " pendingCompletePurchase: " +
            value.pendingCompletePurchase.toString() +
            " acknowledged: " +
            value.billingClientPurchase?.isAcknowledged.toString())
        .join("\n ");

    return 'PurchaseCompletedState{products: $products, '
        'purchases: $purchasesStr, isAvailable: $isAvailable, loading: $loading,'
        ' queryProductError: $serviceError}';
  }
}

class PurchaserBloc implements BasePurchaseBloc {
  InAppPurchaseConnection _connection;
  StreamSubscription<List<PurchaseDetails>> _subscription;

  PurchaseCompletedState _purchaseState;

  PurchaseCompletedState get purchaseState => _purchaseState;

  StreamController<PurchaseCompletedState> _purchaseStateStreamController =
      StreamController.broadcast();

  Stream<PurchaseCompletedState> get purchaseStateStream =>
      _purchaseStateStreamController.stream; //.asBroadcastStream();

  PurchaserBloc() {
    _purchaseState = PurchaseCompletedState.empty();
  }

  enablePendingPurchases() {
    InAppPurchaseConnection.enablePendingPurchases();
  }

  enableConnection() {
    _connection = InAppPurchaseConnection.instance;
  }

  listenPurchaseUpdates() {
    Stream purchaseUpdated =
        InAppPurchaseConnection.instance.purchaseUpdatedStream;
    _subscription = purchaseUpdated.listen((purchaseDetailsList) {
      _listenToPurchaseUpdated(purchaseDetailsList);
    }, onDone: () {
      _subscription?.cancel();
    }, onError: (error) {
      _emitFailedState("Purchase update status failed!");
    });
  }

  /// Get available products
  /// From [productIds]
  Future queryProductDetails(Set<String> productIds) async {
    if (!(await _startConnection())) {
      return false;
    }

    ProductDetailsResponse productDetailResponse =
        await _connection.queryProductDetails(productIds);

    final Map<String, ProductDetails> productsMap = Map.fromIterable(
        productDetailResponse.productDetails,
        key: (item) => item.id,
        value: (item) => item);

    _emitCompleteState(
        _purchaseState.copyWith(products: productsMap).success());
  }

  /// Check purchases
  /// If [acknowledgePendingPurchases] is set then run check
  Future queryPurchases({bool acknowledgePendingPurchases = false}) async {
    if (!(await _startConnection())) {
      return false;
    }

    /// Unlike [queryPurchaseHistory], This does not make a network request and
    /// does not return items that are no longer owned.
    final QueryPurchaseDetailsResponse purchaseResponse =
        await _connection.queryPastPurchases();
    if (purchaseResponse.error != null) {
      _emitFailedState("Query purchases error!");
      return;
    }

    final Map<String, PurchaseDetails> purchasesMap = Map.fromIterable(
        purchaseResponse.pastPurchases,
        key: (item) => item.productID,
        value: (item) => item);

    final newState = _purchaseState.copyWith(purchases: purchasesMap);

    if (acknowledgePendingPurchases) {
      await Future.forEach(purchaseResponse.pastPurchases,
          (PurchaseDetails purchasesDetail) async {
        if (purchasesDetail.status == PurchaseStatus.purchased) {
          _acknowledgePurchase(purchasesDetail);
        }
      });
    }

    _emitCompleteState(newState.success());
  }

  /// Callback for get changes of product state
  Future _updatePurchases(List<PurchaseDetails> purchasesDetails) async {
    if (!(await _startConnection())) {
      return false;
    }

    Map<String, String> productErrors = {};

    await Future.forEach(purchasesDetails,
        (PurchaseDetails purchasesDetail) async {
      if (purchasesDetail.status != PurchaseStatus.pending) {
        if (purchasesDetail.status == PurchaseStatus.error) {
          productErrors[purchasesDetail.productID] = "Product purchase error!";
        } else if (purchasesDetail.status == PurchaseStatus.purchased) {
          // Check receipt in this place
          await _acknowledgePurchase(purchasesDetail);
        }
      }
    });

    if (productErrors.length > 0) {
      _emitCompleteState(_purchaseState.copyWith(productErrors: productErrors));
    }

    await queryPurchases();
  }

  Future<bool> _acknowledgePurchase(PurchaseDetails purchasesDetail) async {
    if (purchasesDetail.pendingCompletePurchase) {
      final completeResult = await InAppPurchaseConnection.instance
          .completePurchase(purchasesDetail);
      return completeResult.responseCode == BillingResponse.ok;
    }

    return false;
  }

  /// Request purchase flow
  /// [productId] - Id of product
  Future requestPurchase(String productId) async {
    if (!(await _startConnection())) {
      return false;
    }

    ProductDetailsResponse productDetailResponse =
        await _connection.queryProductDetails({productId});

    if (productDetailResponse.error != null) {
      _emitFailedState("Query products request error!");
      return false;
    }

    final existsProducts =
        productDetailResponse.productDetails.any((element) => true);
    if (!existsProducts) {
      _emitFailedState("No products error!");
      return false;
    }

    PurchaseParam purchaseParam = PurchaseParam(
        productDetails: productDetailResponse.productDetails
            .where((element) => element.id == productId)
            .first); // applicationUserName: null, sandboxTesting: true);

    _connection.buyNonConsumable(purchaseParam: purchaseParam);
  }

  Future _listenToPurchaseUpdated(
      List<PurchaseDetails> purchaseDetailsList) async {
    await _updatePurchases(purchaseDetailsList);
  }

  _emitLoadingState() {
    _emitState(_purchaseState.copyWith(loading: true));
  }

  _emitFailedState(String purchaseMessage, {bool serviceIsAvailable = true}) {
    _emitState(_purchaseState.copyWith(
        serviceError: purchaseMessage,
        isAvailable: serviceIsAvailable,
        loading: false));
  }

  _emitCompleteState(PurchaseCompletedState basePurchaseState) {
    _emitState(basePurchaseState);
  }

  _emitState(PurchaseCompletedState basePurchaseState) {
    debugPrint("Emited purchase state: ${basePurchaseState.toString()}");
    _purchaseState = basePurchaseState;
    _purchaseStateStreamController.sink.add(basePurchaseState);
  }

  /// Open and check connection to Billing service
  /// Return [true] if success
  Future<bool> _startConnection() async {
    final isAvailability = await _connection.isAvailable();

    if (!isAvailability) {
      _emitFailedState("Billing service is unavailable!",
          serviceIsAvailable: false);
    } else {
      _emitLoadingState();
    }

    return isAvailability;
  }

  dispose() {
    _purchaseStateStreamController?.close();
  }
}
