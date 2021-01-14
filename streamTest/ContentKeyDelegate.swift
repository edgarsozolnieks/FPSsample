/*
 Copyright (C) 2017 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 `ContentKeyDelegate` is a class that implements the `AVContentKeySessionDelegate` protocol to respond to content key
 requests using FairPlay Streaming.
 */

import AVFoundation
import AVKit

class ContentKeyDelegate: NSObject, AVContentKeySessionDelegate {
    
    private let certificateUrl: String = "https://widevine-test.helio.lv/FPScertificate"
    private let drmUrl: String = "https://widevine-test.helio.lv/FPSlicenceservice"
    
    // MARK: Types
    
    enum ProgramError: Error {
        case missingApplicationCertificate
        case noCKCReturnedByKSM
    }
    
    // MARK: Properties
    
    /// The directory that is used to save persistable content keys.
    lazy var contentKeyDirectory: URL = {
        guard let documentPath =
            NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else {
                fatalError("Unable to determine library URL")
        }
        
        let documentURL = URL(fileURLWithPath: documentPath)
        
        let contentKeyDirectory = documentURL.appendingPathComponent(".keys", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: contentKeyDirectory.path, isDirectory: nil) {
            do {
                try FileManager.default.createDirectory(at: contentKeyDirectory,
                                                    withIntermediateDirectories: false,
                                                    attributes: nil)
            } catch {
                fatalError("Unable to create directory for content keys at path: \(contentKeyDirectory.path)")
            }
        }
        
        return contentKeyDirectory
    }()
    
    /// A set containing the currently pending content key identifiers associated with persistable content key requests that have not been completed.
    var pendingPersistableContentKeyIdentifiers = Set<String>()
    
    /// A dictionary mapping content key identifiers to their associated stream name.
    var contentKeyToStreamNameMap = [String: String]()
    
    func requestApplicationCertificate() throws -> Data {
        var applicationCertificate: Data? = nil
        
        let semaphore = DispatchSemaphore(value: 0)

        if let certificateUrl = URL(string: self.certificateUrl) {
            var request = URLRequest(url: certificateUrl)
            request.httpMethod = "GET"
            
            URLSession.shared.dataTask(with: request) { (data, _, error) in
                if let data = data {
                    applicationCertificate = data
                } else {
                    print("Error encountered while fetching FairPlay certificate for URL: \(self.certificateUrl), \(error?.localizedDescription ?? "Unknown error")")
                }
                
                semaphore.signal()
            }.resume()
        } else {
            print("failed drm request")
            semaphore.signal()
        }
        
        semaphore.wait()
        
        guard applicationCertificate != nil else {
            throw ProgramError.missingApplicationCertificate
        }
        
        return applicationCertificate!
    }
    
    func requestContentKeyFromKeySecurityModule(spcData: Data, assetID: String) throws -> Data {
        var ckcData: Data? = nil
        
        let semaphore = DispatchSemaphore(value: 0)
        
        // TODO - fix body
        let postString = "spc=\(spcData.base64EncodedString())&assetId=\(assetID)"
        
        if let postData = postString.data(using: .ascii, allowLossyConversion: true), let drmServerUrl = URL(string: self.drmUrl) {
            var request = URLRequest(url: drmServerUrl)
            request.httpMethod = "POST"
            request.setValue(String(postData.count), forHTTPHeaderField: "Content-Length")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = postData
            
            URLSession.shared.dataTask(with: request) { (data, _, error) in
                if let data = data, var responseString = String(data: data, encoding: .utf8) {
                    responseString = responseString.replacingOccurrences(of: "<ckc>", with: "").replacingOccurrences(of: "</ckc>", with: "")
                    ckcData = Data(base64Encoded: responseString)
                } else {
                    print("Error encountered while fetching FairPlay license for URL: \(self.drmUrl), \(error?.localizedDescription ?? "Unknown error")")
                }
                
                semaphore.signal()
            }.resume()
        } else {
            print("failed drm request")
            semaphore.signal()
        }
        
        semaphore.wait()
        
        guard ckcData != nil else {
            throw ProgramError.noCKCReturnedByKSM
        }
        
        return ckcData!
    }

    /// Preloads all the content keys associated with an Asset for persisting on disk.
    ///
    /// It is recommended you use AVContentKeySession to initiate the key loading process
    /// for online keys too. Key loading time can be a significant portion of your playback
    /// startup time because applications normally load keys when they receive an on-demand
    /// key request. You can improve the playback startup experience for your users if you
    /// load keys even before the user has picked something to play. AVContentKeySession allows
    /// you to initiate a key loading process and then use the key request you get to load the
    /// keys independent of the playback session. This is called key preloading. After loading
    /// the keys you can request playback, so during playback you don't have to load any keys,
    /// and the playback decryption can start immediately.
    ///
    /// In this sample use the Streams.plist to specify your own content key identifiers to use
    /// for loading content keys for your media. See the README document for more information.
    ///
    /// - Parameter asset: The `Asset` to preload keys for.
    func requestPersistableContentKeys(forAsset asset: Asset) {
        for identifier in asset.stream.contentKeyIDList ?? [] {
            
            guard let contentKeyIdentifierURL = URL(string: identifier), let assetIDString = contentKeyIdentifierURL.host else { continue }
            
            pendingPersistableContentKeyIdentifiers.insert(assetIDString)
            contentKeyToStreamNameMap[assetIDString] = asset.stream.name
            
            ContentKeyManager.shared.contentKeySession.processContentKeyRequest(withIdentifier: identifier, initializationData: nil, options: nil)
        }
    }
    
    /// Returns whether or not a content key should be persistable on disk.
    ///
    /// - Parameter identifier: The asset ID associated with the content key request.
    /// - Returns: `true` if the content key request should be persistable, `false` otherwise.
    func shouldRequestPersistableContentKey(withIdentifier identifier: String) -> Bool {
        return pendingPersistableContentKeyIdentifiers.contains(identifier)
    }
    
    // MARK: AVContentKeySessionDelegate Methods
    
    /*
     The following delegate callback gets called when the client initiates a key request or AVFoundation
     determines that the content is encrypted based on the playlist the client provided when it requests playback.
     */
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handleStreamingContentKeyRequest(keyRequest: keyRequest)
    }
    
    /*
     Provides the receiver with a new content key request representing a renewal of an existing content key.
     Will be invoked by an AVContentKeySession as the result of a call to -renewExpiringResponseDataForContentKeyRequest:.
     */
    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        handleStreamingContentKeyRequest(keyRequest: keyRequest)
    }
    
    /*
     Provides the receiver a content key request that should be retried because a previous content key request failed.
     Will be invoked by an AVContentKeySession when a content key request should be retried. The reason for failure of
     previous content key request is specified. The receiver can decide if it wants to request AVContentKeySession to
     retry this key request based on the reason. If the receiver returns YES, AVContentKeySession would restart the
     key request process. If the receiver returns NO or if it does not implement this delegate method, the content key
     request would fail and AVContentKeySession would let the receiver know through
     -contentKeySession:contentKeyRequest:didFailWithError:.
     */
    
    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest, reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        var shouldRetry = false
        
        switch retryReason {
            /*
             Indicates that the content key request should be retried because the key response was not set soon enough either
             due the initial request/response was taking too long, or a lease was expiring in the meantime.
             */
        case AVContentKeyRequest.RetryReason.timedOut:
            shouldRetry = true
            
            /*
             Indicates that the content key request should be retried because a key response with expired lease was set on the
             previous content key request.
             */
        case AVContentKeyRequest.RetryReason.receivedResponseWithExpiredLease:
            shouldRetry = true
            
            /*
             Indicates that the content key request should be retried because an obsolete key response was set on the previous
             content key request.
             */
        case AVContentKeyRequest.RetryReason.receivedObsoleteContentKey:
            shouldRetry = true
            
        default:
            break
        }
        
        return shouldRetry
    }
    
    // Informs the receiver a content key request has failed.
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: Error) {
        // Add your code here to handle errors.
        print(err)
    }
    
    // MARK: API
    
    func handleStreamingContentKeyRequest(keyRequest: AVContentKeyRequest) {
        guard let contentKeyIdentifierString = keyRequest.identifier as? String,
            let contentKeyIdentifierURL = URL(string: contentKeyIdentifierString),
            let assetIDString = contentKeyIdentifierURL.host,
            let assetIDData = assetIDString.data(using: .utf8)
            else {
                print("Failed to retrieve the assetID from the keyRequest!")
                return
        }

        let provideOnlinekey: () -> Void = { () -> Void in

            do {
                let applicationCertificate = try self.requestApplicationCertificate()

                let completionHandler = { [weak self] (spcData: Data?, error: Error?) in
                    guard let strongSelf = self else { return }
                    if let error = error {
                        keyRequest.processContentKeyResponseError(error)
                        return
                    }

                    guard let spcData = spcData else { return }

                    do {
                        // Send SPC to Key Server and obtain CKC
                        let ckcData = try strongSelf.requestContentKeyFromKeySecurityModule(spcData: spcData, assetID: assetIDString)

                        /*
                         AVContentKeyResponse is used to represent the data returned from the key server when requesting a key for
                         decrypting content.
                         */
                        let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckcData)

                        /*
                         Provide the content key response to make protected content available for processing.
                         */
                        keyRequest.processContentKeyResponse(keyResponse)
                    } catch {
                        keyRequest.processContentKeyResponseError(error)
                    }
                }
            
                // TODO - fix parameters
                keyRequest.makeStreamingContentKeyRequestData(forApp: applicationCertificate,
                                                              contentIdentifier: assetIDData,
                                                              options: [AVContentKeyRequestProtocolVersionsKey: [1]],
                                                              completionHandler: completionHandler)
            } catch {
                keyRequest.processContentKeyResponseError(error)
            }
        }

        #if os(iOS)
            /*
             When you receive an AVContentKeyRequest via -contentKeySession:didProvideContentKeyRequest:
             and you want the resulting key response to produce a key that can persist across multiple
             playback sessions, you must invoke -respondByRequestingPersistableContentKeyRequest on that
             AVContentKeyRequest in order to signal that you want to process an AVPersistableContentKeyRequest
             instead. If the underlying protocol supports persistable content keys, in response your
             delegate will receive an AVPersistableContentKeyRequest via -contentKeySession:didProvidePersistableContentKeyRequest:.
             */
            if shouldRequestPersistableContentKey(withIdentifier: assetIDString) ||
                persistableContentKeyExistsOnDisk(withContentKeyIdentifier: assetIDString) {
                
                // Request a Persistable Key Request.
                do {
                    try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError()
                } catch {

                    /*
                    This case will occur when the client gets a key loading request from an AirPlay Session.
                    You should answer the key request using an online key from your key server.
                    */
                    provideOnlinekey()
                }
                
                return
            }
        #endif
        
        provideOnlinekey()
    }
    
    func makeStreamingContentKeyRequestData(initData: String, id: Data, cert: Data) -> Data {
        guard var result = initData.data(using: .utf8) else {
            fatalError()
        }
        result.append(id)
        result.append(cert)
        
        // layout is [initData][4 byte: idLength][idLength byte: id][4 byte:certLength][certLength byte: cert]
        return result
    }
    
    /*function concatInitDataIdAndCertificate(initData, id, cert) {
        window.console.error(typeof id);
        if (typeof id == "string")
            id = stringToArray(id);
          //  window.console.error(id);

        // layout is [initData][4 byte: idLength][idLength byte: id][4 byte:certLength][certLength byte: cert]
        var offset = 0;
        var buffer = new ArrayBuffer(initData.byteLength + 4 + id.byteLength + 4 + cert.byteLength);
        var dataView = new DataView(buffer);

        var initDataArray = new Uint8Array(buffer, offset, initData.byteLength);
        initDataArray.set(initData);
        offset += initData.byteLength;

        dataView.setUint32(offset, id.byteLength, true);
        offset += 4;

        var idArray = new Uint16Array(buffer, offset, id.length);
        idArray.set(id);
        offset += idArray.byteLength;

        dataView.setUint32(offset, cert.byteLength, true);
        offset += 4;

        var certArray = new Uint8Array(buffer, offset, cert.byteLength);
        certArray.set(cert);

        return new Uint8Array(buffer, 0, buffer.byteLength);
    }*/
}
