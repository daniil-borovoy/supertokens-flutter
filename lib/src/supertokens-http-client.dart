import 'dart:collection';

import 'package:http/http.dart' as http;
import 'package:supertokens/src/anti-csrf.dart';
import 'package:supertokens/src/id-refresh-token.dart';
import 'package:supertokens/src/utilities.dart';
import 'package:supertokens/supertokens.dart';

import 'constants.dart';

/// An [http.BaseClient] implementation for using SuperTokens for your network requests.
/// To make use of supertokens, use this as the client for making network calls instead of [http.Client] or your own custom clients.
/// If you use a custom client for your network calls pass an instance of it as a paramtere when initialising [SuperTokensHttpClient], pass [http.Client()] to use the default.
class SuperTokensHttpClient extends http.BaseClient {
  final http.Client _innerClient;

  SuperTokensHttpClient(this._innerClient);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!SuperTokens.isInitCalled) {
      throw http.ClientException(
          "SuperTokens.initialise must be called before using SuperTokensHttpClient");
    }

    if (SuperTokensUtils.getApiDomain(request.url.toString()) !=
        SuperTokens.apiDomain) {
      return _innerClient.send(request);
    }

    if (SuperTokensUtils.getApiDomain(request.url.toString()) ==
        SuperTokens.refreshTokenEndpoint) {
      return _innerClient.send(request);
    }

    try {
      while (true) {
        // TODO: Aquire read lock, from read write lock
        String? preRequestIdRefreshToken;
        http.StreamedResponse response;
        try {
          preRequestIdRefreshToken = await IdRefreshToken.getToken();
          String? antiCSRFToken =
              await AntiCSRF.getToken(preRequestIdRefreshToken);

          if (antiCSRFToken != null) {
            request.headers[antiCSRFHeaderKey] = antiCSRFToken;
          }

          if (preRequestIdRefreshToken != null) {
            request.headers[superTokensPlatformHeaderKey] =
                superTokensPlatformName;
            request.headers[superTokensSDKVersionHeaderKey] =
                superTokensPluginVersion;
          }

          response = await _innerClient.send(request);

          String? idRefreshTokenFromResponse =
              response.headers[idRefreshHeaderKey];
          if (idRefreshTokenFromResponse != null) {
            await IdRefreshToken.setToken(idRefreshTokenFromResponse);
          }
        } finally {
          // TODO: unlock read lock
        }

        if (response.statusCode == SuperTokens.sessionExpiryStatusCode) {
          bool shouldRetry =
              await _handleUnauthorised(preRequestIdRefreshToken, request);
          if (!shouldRetry) {
            return response;
          }
        } else {
          String? antiCSRFFromResponse = response.headers[antiCSRFHeaderKey];
          if (antiCSRFFromResponse != null) {
            String? postRequestIdRefresh = await IdRefreshToken.getToken();
            await AntiCSRF.setToken(
              antiCSRFFromResponse,
              postRequestIdRefresh,
            );
          }
          return response;
        }
      }
    } finally {
      String? idRefreshToken = await IdRefreshToken.getToken();
      if (idRefreshToken == null) {
        await AntiCSRF.removeToken();
      }
    }
  }

  Future<bool> _handleUnauthorised(
      String? preRequestIdRefreshToken, http.BaseRequest request) async {
    if (preRequestIdRefreshToken == null) {
      String? idRefresh = await IdRefreshToken.getToken();
      return idRefresh != null;
    }

    _UnauthorisedResponse _unauthorisedResponse =
        await onUnauthorisedResponseRecieved(SuperTokens.refreshTokenEndpoint,
            preRequestIdRefreshToken, request);

    if (_unauthorisedResponse.status == _UnauthorisedStatus.SESSION_EXPIRED) {
      return false;
    } else if (_unauthorisedResponse.status == _UnauthorisedStatus.API_ERROR) {
      throw _unauthorisedResponse.exception ??
          http.ClientException("Network call completed with an error");
    }

    return true;
  }

  Future<_UnauthorisedResponse> onUnauthorisedResponseRecieved(
      String refreshEndpointURL,
      String preRequestIdRefreshToken,
      http.BaseRequest request) async {
    // this is intentionally not put in a loop because the loop in other projects is because locking has a timeout
    http.Response refreshResponse;
    try {
      // TODO: Aquire write lock
      String? postLockIdRefresh = await IdRefreshToken.getToken();

      if (postLockIdRefresh == null) {
        return _UnauthorisedResponse(
            status: _UnauthorisedStatus.SESSION_EXPIRED);
      }

      if (postLockIdRefresh != preRequestIdRefreshToken) {
        return _UnauthorisedResponse(status: _UnauthorisedStatus.RETRY);
      }

      Map<String, String> refreshHeaders = HashMap();
      String? antiCSRF = await AntiCSRF.getToken(preRequestIdRefreshToken);

      if (antiCSRF != null) {
        refreshHeaders[antiCSRFHeaderKey] = antiCSRF;
      }

      refreshHeaders[superTokensPlatformHeaderKey] = superTokensPlatformName;
      refreshHeaders[superTokensSDKVersionHeaderKey] = superTokensPluginVersion;
      refreshHeaders.addAll(SuperTokens.refreshAPICustomHeaders ?? HashMap());

      refreshResponse = await this
          .post(Uri.parse(refreshEndpointURL), headers: refreshHeaders);

      bool removeIdRefreshToken = true;
      String? idRefreshTokenFromResponse =
          refreshResponse.headers[idRefreshHeaderKey];

      if (idRefreshTokenFromResponse != null) {
        await IdRefreshToken.setToken(idRefreshTokenFromResponse);
        removeIdRefreshToken = false;
      }

      if (refreshResponse.statusCode == SuperTokens.sessionExpiryStatusCode &&
          removeIdRefreshToken) {
        await IdRefreshToken.setToken("remove");
      }

      if (refreshResponse.statusCode != 200) {
        String message = refreshResponse.body;
        throw http.ClientException(message);
      }

      String? idRefreshAfterResponse = await IdRefreshToken.getToken();
      if (idRefreshAfterResponse == null) {
        return _UnauthorisedResponse(
            status: _UnauthorisedStatus.SESSION_EXPIRED);
      }

      String? antiCSRFFromResponse = refreshResponse.headers[antiCSRFHeaderKey];
      if (antiCSRFFromResponse != null) {
        String? idRefreshToken = await IdRefreshToken.getToken();
        await AntiCSRF.setToken(antiCSRFFromResponse, idRefreshToken);
      }

      return _UnauthorisedResponse(status: _UnauthorisedStatus.RETRY);
    } catch (e) {
      http.ClientException exception = http.ClientException(
          "$e"); // Need to do it this way to capture the error message since catch returns a generic object not a class
      String? idRefreshToken = await IdRefreshToken.getToken();
      if (idRefreshToken == null) {
        return _UnauthorisedResponse(
            status: _UnauthorisedStatus.SESSION_EXPIRED);
      }

      return _UnauthorisedResponse(
          status: _UnauthorisedStatus.API_ERROR, exception: exception);
    } finally {
      // TODO: release write lock
    }
  }
}

enum _UnauthorisedStatus {
  SESSION_EXPIRED,
  API_ERROR,
  RETRY,
}

class _UnauthorisedResponse {
  final _UnauthorisedStatus status;
  final http.ClientException? exception;

  _UnauthorisedResponse({
    required this.status,
    this.exception,
  });
}