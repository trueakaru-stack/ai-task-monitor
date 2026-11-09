// swift-tools-version: 5.10
// Only synthetic loopback port zero is used, with no payload.
import Darwin
import Foundation
import PackageDescription

func checkDenial(_ family: Int32) {
    let descriptor = Darwin.socket(family, SOCK_STREAM, 0)
    if descriptor == -1 {
        guard errno == EPERM || errno == EACCES else {
            fatalError("Socket creation failed for an unrelated reason")
        }
        return
    }
    defer { _ = Darwin.close(descriptor) }
    let result: Int32
    if family == AF_INET {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard Darwin.inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            fatalError("Invalid synthetic IPv4 address")
        }
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, size) }
        }
    } else {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        guard Darwin.inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else {
            fatalError("Invalid synthetic IPv6 address")
        }
        let size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, size) }
        }
    }
    let error = errno
    guard result == -1 && (error == EPERM || error == EACCES) else {
        fatalError("The outer sandbox did not deny the synthetic connection")
    }
}

checkDenial(AF_INET)
checkDenial(AF_INET6)
guard let marker = ProcessInfo.processInfo.environment["AITM_SWIFTPM_PROBE_MARKER"] else {
    fatalError("Missing synthetic probe marker")
}
do {
    try "ipv4-and-ipv6-denied\n".write(toFile: marker, atomically: false, encoding: .utf8)
} catch {
    fatalError("Could not write synthetic probe marker")
}
let package = Package(name: "AITMSyntheticNetworkProbe")
