//
//  NetworkUtilities.swift
//  simple web server
//
//  Created by Кирилл Ветров on 12/10/25.
//

import Foundation

class NetworkUtilities {
    static func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return addresses }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            // Check for IPv4 (AF_INET)
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                
                // Skip loopback and only include WiFi/Ethernet interfaces
                if name != "lo0" && (name.hasPrefix("en") || name.hasPrefix("pdp_ip")) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let address = String(cString: hostname)
                        
                        // Only include local network addresses (192.168.x.x, 172.16-31.x.x, not VPN 10.x.x.x)
                        if address.hasPrefix("192.168.") || 
                           (address.hasPrefix("172.") && isPrivateClassB(address)) {
                            addresses.append(address)
                        }
                    }
                }
            }
        }
        
        return addresses
    }
    
    private static func isPrivateClassB(_ address: String) -> Bool {
        let components = address.split(separator: ".")
        guard components.count >= 2,
              let second = Int(components[1]) else { return false }
        return second >= 16 && second <= 31
    }
}
