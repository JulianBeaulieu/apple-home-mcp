import Foundation
import HomeKit
import Matter
import MCPKit

/// Talks Matter to accessories on the Apple Home fabric through HomeKit's XPC-backed Matter
/// controller (`HMHome.matterControllerID` + `matterControllerXPCConnectBlock`, public since
/// iOS 16.1 / Mac Catalyst 16.1). Whether homed lets a third-party app invoke a given command
/// is decided by homed at runtime; see docs/PAIRING.md for what was verified.
@MainActor
final class MatterBridge {
    private var controllers: [UUID: MTRDeviceController] = [:]

    struct Window {
        let manualCode: String
        let qrCode: String?
        let discriminator: Int
        let expires: Date
        let method: String
    }

    func controller(for home: HMHome) throws -> MTRDeviceController {
        if let c = controllers[home.uniqueIdentifier] { return c }
        guard #available(macCatalyst 16.4, *) else { throw ToolError("Matter over HomeKit needs macOS 13.3 or later") }
        let id = home.matterControllerID
        guard !id.isEmpty else { throw ToolError("this home has no Matter controller (no home hub, or Matter not set up)") }
        let c = MTRDeviceController.sharedController(withID: id as NSString, xpcConnect: home.matterControllerXPCConnectBlock)
        controllers[home.uniqueIdentifier] = c
        return c
    }

    func nodeID(_ a: HMAccessory) throws -> UInt64 {
        guard #available(macCatalyst 16.1, *), let n = a.matterNodeID, n != 0 else {
            throw ToolError("'\(a.name)' is not a Matter accessory on the Apple Home fabric (it is HomeKit/HAP or bridged). Only Matter accessories can be shared to another controller.")
        }
        return n
    }

    // MARK: Read-only diagnostics

    /// Reads Basic Information (0x0028) and Operational Credentials fabric count (0x003E) over XPC.
    func basicInfo(home: HMHome, accessory: HMAccessory) async throws -> JSONValue {
        let node = try nodeID(accessory)
        let controller = try controller(for: home)
        let device = MTRBaseDevice(nodeID: NSNumber(value: node), controller: controller)
        var out: [String: JSONValue] = ["matter_node_id": .string(String(format: "%016llX", node))]
        let attrs: [(String, UInt32, UInt32)] = [
            ("vendor_name", 0x0028, 0x0001), ("vendor_id", 0x0028, 0x0002), ("product_name", 0x0028, 0x0003),
            ("product_id", 0x0028, 0x0004), ("software_version", 0x0028, 0x000A), ("unique_id", 0x0028, 0x0012),
            ("supported_fabrics", 0x003E, 0x0002), ("commissioned_fabrics", 0x003E, 0x0003),
            ("commissioning_window_status", 0x003C, 0x0000),
        ]
        for (key, cluster, attr) in attrs {
            do {
                let values = try await read(device, endpoint: 0, cluster: cluster, attribute: attr)
                out[key] = values
            } catch {
                out[key] = ["error": .string(error.localizedDescription)]
            }
        }
        // Fabrics (0x003E/0x0001), unfiltered: which ecosystems already control this device.
        // Only vendor id, label and fabric index are returned (no keys).
        do {
            let params = MTRReadParams()
            params.shouldFilterByFabric = false
            let fabrics = try await read(device, endpoint: 0, cluster: 0x003E, attribute: 0x0001, params: params)
            let list = (fabrics.arrayValue ?? [fabrics]).map { f -> JSONValue in
                let vid = f["2"]?.intValue
                return ["vendor_id": vid.map { .number(Double($0)) } ?? .null,
                        "vendor": .string(MatterBridge.vendorName(vid)),
                        "label": f["5"] ?? .null, "fabric_index": f["254"] ?? .null]
            }
            out["fabrics"] = .array(list)
        } catch {
            out["fabrics"] = ["error": .string(error.localizedDescription)]
        }
        if let s = out["commissioning_window_status"]?.intValue {
            out["commissioning_window_status"] = .string(["closed", "enhanced_window_open", "basic_window_open"][min(max(s, 0), 2)])
        }
        return .object(out)
    }

    nonisolated static func vendorName(_ vid: Int?) -> String {
        switch vid {
        case 0x1349?: return "Apple Home"
        case 0x1384?: return "Apple (second Apple fabric)"
        case 0x134B?: return "Home Assistant (Nabu Casa)"
        case 0x6006?: return "Google Home"
        case 0x1217?: return "Amazon Alexa"
        case 0x110A?: return "SmartThings"
        case 0xFFF1?, 0xFFF2?, 0xFFF3?, 0xFFF4?: return "test vendor (e.g. python-matter-server default)"
        case nil: return "unknown"
        default: return "vendor 0x" + String(vid!, radix: 16, uppercase: true)
        }
    }

    private func read(_ device: MTRBaseDevice, endpoint: UInt16, cluster: UInt32, attribute: UInt32, params: MTRReadParams? = nil) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { cont in
            device.readAttributes(withEndpointID: NSNumber(value: endpoint), clusterID: NSNumber(value: cluster),
                                  attributeID: NSNumber(value: attribute), params: params, queue: .main) { values, error in
                if let error { cont.resume(throwing: error); return }
                let decoded = (values ?? []).compactMap { item -> JSONValue? in
                    if let e = item[MTRErrorKey] as? Error { return ["error": .string(e.localizedDescription)] }
                    return MatterBridge.decode(item[MTRDataKey])
                }
                cont.resume(returning: decoded.count == 1 ? decoded[0] : .array(decoded))
            }
        }
    }

    /// Decodes Matter.framework's data-value dictionaries ({type, value}) into JSON.
    nonisolated static func decode(_ any: Any?) -> JSONValue {
        guard let dict = any as? [String: Any], let type = dict[MTRTypeKey] as? String else { return JSONValue(any: any) }
        let value = dict[MTRValueKey]
        switch type {
        case MTRArrayValueType:
            let items = (value as? [[String: Any]]) ?? []
            return .array(items.map { decode($0[MTRDataKey]) })
        case MTRStructureValueType:
            var o: [String: JSONValue] = [:]
            for field in (value as? [[String: Any]]) ?? [] {
                let tag = (field[MTRContextTagKey] as? NSNumber)?.stringValue ?? "?"
                o[tag] = decode(field[MTRDataKey])
            }
            return .object(o)
        case MTROctetStringValueType:
            return .string(((value as? Data) ?? Data()).map { String(format: "%02x", $0) }.joined())
        case MTRNullValueType:
            return .null
        default:
            return JSONValue(any: value)
        }
    }

    // MARK: Commissioning window (multi-admin share)

    /// Opens an Enhanced Commissioning Window on an Apple-fabric Matter accessory so another
    /// controller (e.g. Home Assistant) can join it. Returns a fresh one-time pairing code.
    func openCommissioningWindow(home: HMHome, accessory: HMAccessory, seconds: Int) async throws -> Window {
        guard #available(macCatalyst 16.4, *) else { throw ToolError("needs macOS 13.3 or later") }
        let node = try nodeID(accessory)
        let controller = try controller(for: home)
        let device = MTRBaseDevice(nodeID: NSNumber(value: node), controller: controller)
        let duration = max(180, min(seconds, 900))
        let discriminator = Int.random(in: 0...0xFFF)
        let passcode = MTRSetupPayload.generateRandomSetupPasscode()
        var errors: [String] = []

        // 1) Explicit AdministratorCommissioning.OpenCommissioningWindow (timed invoke) with a
        //    locally computed SPAKE2+ verifier. This only needs the generic invoke path over XPC.
        do {
            var salt = Data(count: 32)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            let iterations = 15000
            let verifier = try MTRDeviceController.computePASEVerifier(forSetupPasscode: passcode, iterations: NSNumber(value: iterations), salt: salt)
            let params = MTRAdministratorCommissioningClusterOpenCommissioningWindowParams()
            params.commissioningTimeout = NSNumber(value: duration)
            params.pakePasscodeVerifier = verifier
            params.discriminator = NSNumber(value: discriminator)
            params.iterations = NSNumber(value: iterations)
            params.salt = salt
            params.timedInvokeTimeoutMs = 10_000
            guard let cluster = MTRBaseClusterAdministratorCommissioning(device: device, endpointID: 0, queue: .main) else {
                throw ToolError("could not create the Administrator Commissioning cluster client")
            }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                cluster.openWindow(with: params) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
            return try window(passcode: passcode, discriminator: discriminator, duration: duration, method: "administrator_commissioning.open_commissioning_window")
        } catch {
            errors.append("OpenCommissioningWindow invoke: \(MatterBridge.describe(error))")
        }

        // 2) Matter.framework's convenience API (computes the verifier itself).
        do {
            let payload: MTRSetupPayload = try await withCheckedThrowingContinuation { cont in
                device.openCommissioningWindow(withSetupPasscode: passcode, discriminator: NSNumber(value: discriminator),
                                               duration: NSNumber(value: duration), queue: .main) { payload, error in
                    if let payload { cont.resume(returning: payload) } else { cont.resume(throwing: error ?? ToolError("no payload")) }
                }
            }
            return Window(manualCode: payload.manualEntryCode() ?? "", qrCode: Self.qr(payload), discriminator: discriminator,
                          expires: Date().addingTimeInterval(TimeInterval(duration)), method: "mtrbasedevice.open_commissioning_window")
        } catch {
            errors.append("MTRBaseDevice.openCommissioningWindow: \(MatterBridge.describe(error))")
        }
        throw ToolError("Apple Home refused to open a commissioning window for '\(accessory.name)'",
                        details: ["attempts": .array(errors.map { .string($0) })])
    }

    /// AdministratorCommissioning.RevokeCommissioning: closes an open commissioning window early.
    func closeCommissioningWindow(home: HMHome, accessory: HMAccessory) async throws {
        guard #available(macCatalyst 16.4, *) else { throw ToolError("needs macOS 13.3 or later") }
        let device = MTRBaseDevice(nodeID: NSNumber(value: try nodeID(accessory)), controller: try controller(for: home))
        guard let cluster = MTRBaseClusterAdministratorCommissioning(device: device, endpointID: 0, queue: .main) else {
            throw ToolError("could not create the Administrator Commissioning cluster client")
        }
        let params = MTRAdministratorCommissioningClusterRevokeCommissioningParams()
        params.timedInvokeTimeoutMs = 10_000
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cluster.revokeCommissioning(with: params) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func window(passcode: NSNumber, discriminator: Int, duration: Int, method: String) throws -> Window {
        let payload = MTRSetupPayload(setupPasscode: passcode, discriminator: NSNumber(value: discriminator))
        guard let manual = payload.manualEntryCode() else { throw ToolError("could not encode the pairing code") }
        return Window(manualCode: manual, qrCode: Self.qr(payload), discriminator: discriminator,
                      expires: Date().addingTimeInterval(TimeInterval(duration)), method: method)
    }

    private static func qr(_ p: MTRSetupPayload) -> String? {
        if #available(iOS 17.6, macCatalyst 17.6, *) { return p.qrCodeString() }
        return nil
    }

    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    /// Parses a Matter onboarding payload (QR "MT:..." or 11/21-digit manual code) without
    /// revealing the passcode.
    nonisolated static func describePayload(_ code: String) -> JSONValue? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard #available(iOS 17.6, macCatalyst 17.6, *), let p = MTRSetupPayload(payload: trimmed) else { return nil }
        var o: [String: JSONValue] = ["kind": .string(trimmed.uppercased().hasPrefix("MT:") ? "qr" : "manual")]
        o["vendor_id"] = .number(p.vendorID.doubleValue)
        o["product_id"] = .number(p.productID.doubleValue)
        o["has_short_discriminator"] = .bool(p.hasShortDiscriminator)
        o["discriminator"] = .number(p.discriminator.doubleValue)
        o["commissioning_flow"] = .number(Double(p.commissioningFlow.rawValue))
        return .object(o)
    }
}
