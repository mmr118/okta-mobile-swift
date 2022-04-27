//
// Copyright (c) 2022-Present, Okta, Inc. and/or its affiliates. All rights reserved.
// The Okta software accompanied by this notice is provided pursuant to the Apache License, Version 2.0 (the "License.")
//
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//
// See the License for the specific language governing permissions and limitations under the License.
//

import Foundation

#if os(Linux)
import FoundationNetworking
#endif

class CredentialCoordinatorImpl: CredentialCoordinator {
    var credentialDataSource: CredentialDataSource {
        didSet {
            credentialDataSource.delegate = self
        }
    }
    
    var tokenStorage: TokenStorage {
        didSet {
            tokenStorage.delegate = self
            
            _default = try? CredentialCoordinatorImpl.defaultCredential(
                tokenStorage: tokenStorage,
                credentialDataSource: credentialDataSource,
                coordinator: self)
        }
    }
        
    private var _default: Credential?
    var `default`: Credential? {
        get { _default }
        set {
            if let token = newValue?.token {
                try? tokenStorage.add(token: token,
                                      security: Credential.Security.standard)
            }
            try? tokenStorage.setDefaultTokenID(newValue?.id)
        }
    }
    
    public var allIDs: [String] {
        tokenStorage.allIDs
    }
    
    func store(token: Token, tags: [String: String], security: [Credential.Security]) throws -> Credential {
        try tokenStorage.add(token: token, security: security)
        try tokenStorage.setMetadata(Token.Metadata(token: token, tags: tags))
        return credentialDataSource.credential(for: token, coordinator: self)
    }
    
    func with(id: String, prompt: String?, authenticationContext: TokenAuthenticationContext?) throws -> Credential? {
        credentialDataSource.credential(for: try tokenStorage.get(token: id,
                                                                  prompt: prompt,
                                                                  authenticationContext: authenticationContext),
                                        coordinator: self)
    }
    
    func find(where expression: @escaping (Token.Metadata) -> Bool,
              prompt: String? = nil,
              authenticationContext: TokenAuthenticationContext? = nil) throws -> [Credential]
    {
        try allIDs
            .map({ id in
                try self.tokenStorage.metadata(for: id)
            })
            .filter(expression)
            .compactMap({ metadata in
                try self.with(id: metadata.id, prompt: prompt, authenticationContext: authenticationContext)
            })
    }
    
    func remove(credential: Credential) throws {
        credentialDataSource.remove(credential: credential)
        try tokenStorage.remove(id: credential.id)
    }
    
    static func defaultTokenStorage() -> TokenStorage {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        KeychainTokenStorage()
        #else
        UserDefaultsTokenStorage()
        #endif
    }
    
    static func defaultCredentialDataSource() -> CredentialDataSource {
        DefaultCredentialDataSource()
    }
    
    static func defaultCredential(tokenStorage: TokenStorage,
                                  credentialDataSource: CredentialDataSource,
                                  coordinator: CredentialCoordinator) throws -> Credential?
    {
        if let defaultTokenId = tokenStorage.defaultTokenID {
            let token = try tokenStorage.get(token: defaultTokenId,
                                             prompt: nil,
                                             authenticationContext: Credential.Security.standard.context)
            return credentialDataSource.credential(for: token, coordinator: coordinator)
        }
        return nil
    }
    
    init(tokenStorage: TokenStorage = defaultTokenStorage(),
         credentialDataSource: CredentialDataSource = defaultCredentialDataSource())
    {
        self.credentialDataSource = credentialDataSource
        self.tokenStorage = tokenStorage

        self.credentialDataSource.delegate = self
        self.tokenStorage.delegate = self

        _default = try? CredentialCoordinatorImpl.defaultCredential(
            tokenStorage: tokenStorage,
            credentialDataSource: credentialDataSource,
            coordinator: self)

        self.observer = NotificationCenter
            .default
            .addObserver(forName: .oauth2ClientCreated,
                         object: nil,
                         queue: nil) { [weak self] notification in
                self?.received(notification: notification)
            }
    }
    
    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer as Any)
        }
    }
    
    private var observer: NSObjectProtocol?
    private func received(notification: Notification) {
        switch notification.name {
        case .oauth2ClientCreated:
            guard let client = notification.object as? OAuth2Client else { break }
            client.add(delegate: self)
        default: break
        }
    }
}

extension CredentialCoordinatorImpl: OAuth2ClientDelegate {
    func api(client: APIClient, didSend request: URLRequest, received error: APIClientError) {
    }

    func oauth(client: OAuth2Client, didRefresh token: Token, replacedWith newToken: Token?) {
        guard let newToken = newToken else {
            return
        }

        do {
            try tokenStorage.replace(token: token.id, with: newToken, security: nil)
        } catch {
            print("Error happened refreshing: \(error)")
        }
    }
}

extension CredentialCoordinatorImpl: TokenStorageDelegate {
    func token(storage: TokenStorage, defaultChanged id: String?) {
        guard _default?.id != id else { return }

        if let id = id,
           let token = try? storage.get(token: id, prompt: nil, authenticationContext: nil)
        {
            _default = credentialDataSource.credential(for: token, coordinator: self)
        } else {
            _default = nil
        }

        NotificationCenter.default.post(name: .defaultCredentialChanged,
                                        object: _default)
    }
    
    func token(storage: TokenStorage, added id: String, token: Token) {
    }
    
    func token(storage: TokenStorage, removed id: String) {
    }
    
    func token(storage: TokenStorage, replaced id: String, with newToken: Token) {
        // Doing nothing with this, for now...
    }
    
}

extension CredentialCoordinatorImpl: CredentialDataSourceDelegate {
    func credential(dataSource: CredentialDataSource, created credential: Credential) {
        credential.coordinator = self
        
        NotificationCenter.default.post(name: .credentialCreated, object: credential)
    }
    
    func credential(dataSource: CredentialDataSource, removed credential: Credential) {
        credential.coordinator = nil

        NotificationCenter.default.post(name: .credentialRemoved, object: credential)
    }
    
    func credential(dataSource: CredentialDataSource, updated credential: Credential) {
    }
}