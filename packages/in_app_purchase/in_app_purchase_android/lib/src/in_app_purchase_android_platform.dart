// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'package:get/get.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import '../billing_client_wrappers.dart';

/// [IAPError.code] code for failed purchases.
const String kPurchaseErrorCode = 'purchase_error';

/// [IAPError.code] code used when a consuming a purchased item fails.
const String kConsumptionFailedErrorCode = 'consume_purchase_failed';

/// [IAPError.code] code used when a query for previous transaction has failed.
const String kRestoredPurchaseErrorCode = 'restore_transactions_failed';

/// Indicates store front is Google Play
const String kIAPSource = 'google_play';

/// An [InAppPurchasePlatform] that wraps Android BillingClient.
///
/// This translates various `BillingClient` calls and responses into the
/// generic plugin API.
class InAppPurchaseAndroidPlatform extends InAppPurchasePlatform {
  InAppPurchaseAndroidPlatform._() {
    billingClient = BillingClient((PurchasesResultWrapper resultWrapper) async {
      _purchaseUpdatedController
          .add(await _getPurchaseDetailsFromResult(resultWrapper));
    });

    // Register [InAppPurchaseAndroidPlatformAddition].
    InAppPurchasePlatformAddition.instance =
        InAppPurchaseAndroidPlatformAddition(billingClient);

    _readyFuture = _connect();
    _purchaseUpdatedController =
        StreamController<List<PurchaseDetails>>.broadcast();
  }

  /// Registers this class as the default instance of [InAppPurchasePlatform].
  static void registerPlatform() {
    // Register the platform instance with the plugin platform
    // interface.
    InAppPurchasePlatform.instance = InAppPurchaseAndroidPlatform._();
  }

  static late StreamController<List<PurchaseDetails>>
      _purchaseUpdatedController;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream =>
      _purchaseUpdatedController.stream;

  /// The [BillingClient] that's abstracted by [GooglePlayConnection].
  ///
  /// This field should not be used out of test code.
  @visibleForTesting
  late final BillingClient billingClient;

  late Future<void> _readyFuture;
  static final Set<String> _productIdsToConsume = <String>{};

  @override
  Future<bool> isAvailable() async {
    await _readyFuture;
    return billingClient.isReady();
  }

  @override
  Future<ProductDetailsResponse> queryProductDetails(
      Set<String> identifiers) async {
    List<SkuDetailsResponseWrapper> responses;
    PlatformException? exception;
    try {
      responses = await Future.wait(<Future<SkuDetailsResponseWrapper>>[
        billingClient.querySkuDetails(
            skuType: SkuType.inapp, skusList: identifiers.toList()),
        billingClient.querySkuDetails(
            skuType: SkuType.subs, skusList: identifiers.toList())
      ]);
    } on PlatformException catch (e) {
      exception = e;
      responses = <SkuDetailsResponseWrapper>[
        // ignore: invalid_use_of_visible_for_testing_member
        SkuDetailsResponseWrapper(
            billingResult: BillingResultWrapper(
                responseCode: BillingResponse.error, debugMessage: e.code),
            skuDetailsList: const <SkuDetailsWrapper>[]),
        // ignore: invalid_use_of_visible_for_testing_member
        SkuDetailsResponseWrapper(
            billingResult: BillingResultWrapper(
                responseCode: BillingResponse.error, debugMessage: e.code),
            skuDetailsList: const <SkuDetailsWrapper>[])
      ];
    }
    final List<ProductDetails> productDetailsList =
        responses.expand((SkuDetailsResponseWrapper response) {
      return response.skuDetailsList;
    }).map((SkuDetailsWrapper skuDetailWrapper) {
      return GooglePlayProductDetails.fromSkuDetails(skuDetailWrapper);
    }).toList();

    final Set<String> successIDS = productDetailsList
        .map((ProductDetails productDetails) => productDetails.id)
        .toSet();
    final List<String> notFoundIDS =
        identifiers.difference(successIDS).toList();
    return ProductDetailsResponse(
        productDetails: productDetailsList,
        notFoundIDs: notFoundIDS,
        error: exception == null
            ? null
            : IAPError(
                source: kIAPSource,
                code: exception.code,
                message: exception.message ?? '',
                details: exception.details));
  }

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    ChangeSubscriptionParam? changeSubscriptionParam;

    if (purchaseParam is GooglePlayPurchaseParam) {
      changeSubscriptionParam = purchaseParam.changeSubscriptionParam;
    }

    final BillingResultWrapper billingResultWrapper =
        await billingClient.launchBillingFlow(
            sku: purchaseParam.productDetails.id,
            accountId: purchaseParam.applicationUserName,
            oldSku: changeSubscriptionParam?.oldPurchaseDetails.productID,
            purchaseToken: changeSubscriptionParam
                ?.oldPurchaseDetails.verificationData.serverVerificationData,
            prorationMode: changeSubscriptionParam?.prorationMode);
    return billingResultWrapper.responseCode == BillingResponse.ok;
  }

  @override
  Future<bool> buyConsumable(
      {required PurchaseParam purchaseParam, bool autoConsume = true}) {
    if (autoConsume) {
      _productIdsToConsume.add(purchaseParam.productDetails.id);
    }
    return buyNonConsumable(purchaseParam: purchaseParam);
  }

  @override
  Future<BillingResultWrapper> completePurchase(
      PurchaseDetails purchase) async {
    assert(
      purchase is GooglePlayPurchaseDetails,
      'On Android, the `purchase` should always be of type `GooglePlayPurchaseDetails`.',
    );

    final GooglePlayPurchaseDetails googlePurchase =
        purchase as GooglePlayPurchaseDetails;

    if (googlePurchase.billingClientPurchase.isAcknowledged) {
      return const BillingResultWrapper(responseCode: BillingResponse.ok);
    }

    if (googlePurchase.verificationData == null) {
      throw ArgumentError(
          'completePurchase unsuccessful. The `purchase.verificationData` is not valid');
    }

    return await billingClient
        .acknowledgePurchase(purchase.verificationData.serverVerificationData);
  }

  @override
  Future<void> restorePurchases({
    String? applicationUserName,
  }) async {
    List<PurchasesResultWrapper> responses;

    responses = await Future.wait(<Future<PurchasesResultWrapper>>[
      billingClient.queryPurchases(SkuType.inapp),
      billingClient.queryPurchases(SkuType.subs)
    ]);

    final Set<String> errorCodeSet = responses
        .where((PurchasesResultWrapper response) =>
    response.responseCode != BillingResponse.ok)
        .map((PurchasesResultWrapper response) =>
        response.responseCode.toString())
        .toSet();

    final String errorMessage =
    errorCodeSet.isNotEmpty ? errorCodeSet.join(', ') : '';

    final List<PurchaseDetails> pastPurchases =
    responses.expand((PurchasesResultWrapper response) {
      return response.purchasesList;
    }).map((PurchaseWrapper purchaseWrapper) {
      final GooglePlayPurchaseDetails purchaseDetails =
      GooglePlayPurchaseDetails.fromPurchase(purchaseWrapper);

      purchaseDetails.status = PurchaseStatus.restored;

      return purchaseDetails;
    }).toList();

    if (errorMessage.isNotEmpty) {
      throw InAppPurchaseException(
        source: kIAPSource,
        code: kRestoredPurchaseErrorCode,
        message: errorMessage,
      );
    }
    if (pastPurchases.length==0)
    {
      Get.defaultDialog(title: "Status" ,  middleText: "Restore purchased failed!" , actions: [Center(child: RaisedButton(color: Colors.orange,onPressed: (){Get.back();},child: Text("Okay", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),),),)]);

    }
    else {
      Get.defaultDialog(title: "Status" ,  middleText: "Restore purchased successful!" , actions: [Center(child: RaisedButton(color: Colors.orange,onPressed: (){Get.back();},child: Text("Okay", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),),),)]);

    }
    _purchaseUpdatedController.add(pastPurchases);

  }

  @override
  Future<bool> verifyPurchases({
    String? applicationUserName,
  }) async {
    List<PurchasesResultWrapper> responses;

    responses = await Future.wait(<Future<PurchasesResultWrapper>>[
      billingClient.queryPurchases(SkuType.inapp),
      billingClient.queryPurchases(SkuType.subs)
    ]);

    final Set<String> errorCodeSet = responses
        .where((PurchasesResultWrapper response) =>
    response.responseCode != BillingResponse.ok)
        .map((PurchasesResultWrapper response) =>
        response.responseCode.toString())
        .toSet();

    final String errorMessage =
    errorCodeSet.isNotEmpty ? errorCodeSet.join(', ') : '';

    final List<PurchaseDetails> pastPurchases =
    responses.expand((PurchasesResultWrapper response) {
      return response.purchasesList;
    }).map((PurchaseWrapper purchaseWrapper) {
      final GooglePlayPurchaseDetails purchaseDetails =
      GooglePlayPurchaseDetails.fromPurchase(purchaseWrapper);



      return purchaseDetails;
    }).toList();

    if (errorMessage.isNotEmpty) {
      return false;
    }
    if (pastPurchases.length==0)
    {
      return false;
    }
    else {
      return true;
    }


  }


  Future<void> _connect() =>
      billingClient.startConnection(onBillingServiceDisconnected: () {});

  Future<PurchaseDetails> _maybeAutoConsumePurchase(
      PurchaseDetails purchaseDetails) async {
    if (!(purchaseDetails.status == PurchaseStatus.purchased &&
        _productIdsToConsume.contains(purchaseDetails.productID))) {
      return purchaseDetails;
    }

    final BillingResultWrapper billingResult =
        await (InAppPurchasePlatformAddition.instance!
                as InAppPurchaseAndroidPlatformAddition)
            .consumePurchase(purchaseDetails);
    final BillingResponse consumedResponse = billingResult.responseCode;
    if (consumedResponse != BillingResponse.ok) {
      purchaseDetails.status = PurchaseStatus.error;
      purchaseDetails.error = IAPError(
        source: kIAPSource,
        code: kConsumptionFailedErrorCode,
        message: consumedResponse.toString(),
        details: billingResult.debugMessage,
      );
    }
    _productIdsToConsume.remove(purchaseDetails.productID);

    return purchaseDetails;
  }

  Future<List<PurchaseDetails>> _getPurchaseDetailsFromResult(
      PurchasesResultWrapper resultWrapper) async {
    IAPError? error;
    if (resultWrapper.responseCode != BillingResponse.ok) {
      error = IAPError(
        source: kIAPSource,
        code: kPurchaseErrorCode,
        message: resultWrapper.responseCode.toString(),
        details: resultWrapper.billingResult.debugMessage,
      );
    }
    final List<Future<PurchaseDetails>> purchases =
        resultWrapper.purchasesList.map((PurchaseWrapper purchase) {
      final GooglePlayPurchaseDetails googlePlayPurchaseDetails =
          GooglePlayPurchaseDetails.fromPurchase(purchase)..error = error;
      if (resultWrapper.responseCode == BillingResponse.userCanceled) {
        googlePlayPurchaseDetails.status = PurchaseStatus.canceled;
      }
      return _maybeAutoConsumePurchase(googlePlayPurchaseDetails);
    }).toList();
    if (purchases.isNotEmpty) {
      return Future.wait(purchases);
    } else {
      PurchaseStatus status = PurchaseStatus.error;
      if (resultWrapper.responseCode == BillingResponse.userCanceled) {
        status = PurchaseStatus.canceled;
      } else if (resultWrapper.responseCode == BillingResponse.ok) {
        status = PurchaseStatus.purchased;
      }
      return <PurchaseDetails>[
        PurchaseDetails(
            purchaseID: '',
            productID: '',
            status: status,
            transactionDate: null,
            verificationData: PurchaseVerificationData(
                localVerificationData: '',
                serverVerificationData: '',
                source: kIAPSource))
          ..error = error
      ];
    }
  }
}
