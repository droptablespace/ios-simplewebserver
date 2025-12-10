//
//  SecurityManager.swift
//  simple web server
//
//  Created by Кирилл Ветров on 12/10/25.
//

import Foundation
import FlyingFox
import Combine
class SecurityManager: ObservableObject {
    @Published var secureMode = false
    @Published var authorizedCodes: Set<String> = []
    
    // MARK: - Authorization
    
    func authorizeCode(_ code: String) {
        authorizedCodes.insert(code)
        print("✅ Authorized code: \(code)")
    }
    
    func validateSessionCode(from request: HTTPRequest) -> Bool {
        // Check if session code is in cookies
        if let cookies = request.headers[HTTPHeader("Cookie")] {
            let cookiePairs = cookies.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            for pair in cookiePairs {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 && parts[0] == "session_code" {
                    let code = String(parts[1])
                    return authorizedCodes.contains(code)
                }
            }
        }
        
        // Check if session code is in query parameters
        if let code = request.query["session_code"] {
            return authorizedCodes.contains(code)
        }
        
        return false
    }
    
    func clearAuthorizedCodes() {
        authorizedCodes.removeAll()
    }
}
