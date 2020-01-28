//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import SignalServiceKit
import SignalMetadataKit
import ZKGroup

@objc
public class GroupsV2Impl: NSObject, GroupsV2, GroupsV2Swift {

    // MARK: - Dependencies

    fileprivate var tsAccountManager: TSAccountManager {
        return TSAccountManager.sharedInstance()
    }

    fileprivate var databaseStorage: SDSDatabaseStorage {
        return SDSDatabaseStorage.shared
    }

    fileprivate var socketManager: TSSocketManager {
        return TSSocketManager.shared
    }

    fileprivate var networkManager: TSNetworkManager {
        return SSKEnvironment.shared.networkManager
    }

    fileprivate var sessionManager: AFHTTPSessionManager {
        return OWSSignalService.sharedInstance().storageServiceSessionManager
    }

    fileprivate var profileManager: OWSProfileManager {
        return OWSProfileManager.shared()
    }

    fileprivate var groupV2Updates: GroupV2Updates {
        return SSKEnvironment.shared.groupV2Updates
    }

    // MARK: -

    public typealias ProfileKeyCredentialMap = [UUID: ProfileKeyCredential]

    @objc
    public required override init() {
        super.init()

        SwiftSingletons.register(self)
    }

    // MARK: - Create Group

    @objc
    public func createNewGroupOnServiceObjc(groupModel: TSGroupModel) -> AnyPromise {
        return AnyPromise(createNewGroupOnService(groupModel: groupModel))
    }

    public func createNewGroupOnService(groupModel: TSGroupModel) -> Promise<Void> {
        // GroupsV2 TODO: Should we make sure we have a local profile credential?
        guard let localUuid = tsAccountManager.localUuid else {
            return Promise<Void>(error: OWSAssertionError("Missing localUuid."))
        }
        let sessionManager = self.sessionManager
        let groupV2Params: GroupV2Params
        do {
            groupV2Params = try GroupV2Params(groupModel: groupModel)
        } catch {
            return Promise<Void>(error: error)
        }
        return DispatchQueue.global().async(.promise) { () -> [UUID] in
            // Gather the UUIDs for all members.
            // We cannot gather profile key credentials for pending members, by definition.
            let uuids = self.uuids(for: groupModel.groupMembers)
            guard uuids.contains(localUuid) else {
                throw OWSAssertionError("localUuid is not a member.")
            }
            return uuids
        }.then(on: DispatchQueue.global()) { (uuids: [UUID]) -> Promise<ProfileKeyCredentialMap> in
            // Gather the profile key credentials for all members.
            let allUuids = uuids + [localUuid]
            return self.loadProfileKeyCredentialData(for: allUuids)
        }.then(on: DispatchQueue.global()) { (profileKeyCredentialMap: ProfileKeyCredentialMap) -> Promise<NSURLRequest> in
            // Build the request.
            return self.buildNewGroupRequest(groupModel: groupModel,
                                             localUuid: localUuid,
                                             profileKeyCredentialMap: profileKeyCredentialMap,
                                             groupV2Params: groupV2Params,
                                             sessionManager: sessionManager)
        }.then(on: DispatchQueue.global()) { (request: NSURLRequest) -> Promise<ServiceResponse> in
            return self.performServiceRequest(request: request, sessionManager: sessionManager)
        }.asVoid()
    }

    private func buildNewGroupRequest(groupModel: TSGroupModel,
                                      localUuid: UUID,
                                      profileKeyCredentialMap: ProfileKeyCredentialMap,
                                      groupV2Params: GroupV2Params,
                                      sessionManager: AFHTTPSessionManager) -> Promise<NSURLRequest> {

        return retrieveCredentials(localUuid: localUuid)
            .map(on: DispatchQueue.global()) { (authCredentialMap: [UInt32: AuthCredential]) -> NSURLRequest in

                let groupProto = try GroupsV2Protos.buildNewGroupProto(groupModel: groupModel,
                                                                       groupV2Params: groupV2Params,
                                                                       profileKeyCredentialMap: profileKeyCredentialMap,
                                                                       localUuid: localUuid)
                let redemptionTime = self.daysSinceEpoch
                return try StorageService.buildNewGroupRequest(groupProto: groupProto,
                                                               groupV2Params: groupV2Params,
                                                               sessionManager: sessionManager,
                                                               authCredentialMap: authCredentialMap,
                                                               redemptionTime: redemptionTime)
        }
    }

    // MARK: - Update Group

    public func updateExistingGroupOnService(changeSet: GroupsV2ChangeSet) -> Promise<UpdatedV2Group> {
        let groupId = changeSet.groupId

        // GroupsV2 TODO: Should we make sure we have a local profile credential?
        guard let localUuid = tsAccountManager.localUuid else {
            return Promise(error: OWSAssertionError("Missing localUuid."))
        }
        let sessionManager = self.sessionManager
        let groupV2Params: GroupV2Params
        do {
            groupV2Params = try GroupV2Params(groupSecretParamsData: changeSet.groupSecretParamsData)
        } catch {
            return Promise(error: error)
        }
        return self.databaseStorage.read(.promise) { transaction in
            return TSGroupThread.fetch(groupId: groupId, transaction: transaction)
        }.then(on: DispatchQueue.global()) { (thread: TSGroupThread?) -> Promise<GroupsProtoGroupChangeActions> in
            guard let thread = thread else {
                throw OWSAssertionError("Thread does not exist.")
            }
            return changeSet.buildGroupChangeProto(currentGroupModel: thread.groupModel)
        }.then(on: DispatchQueue.global()) { (groupChangeProto: GroupsProtoGroupChangeActions) -> Promise<NSURLRequest> in
            // GroupsV2 TODO: We should implement retry for all request methods in this class.
            return self.buildUpdateGroupRequest(localUuid: localUuid,
                                                groupV2Params: groupV2Params,
                                                groupChangeProto: groupChangeProto,
                                                sessionManager: sessionManager)
        }.then(on: DispatchQueue.global()) { (request: NSURLRequest) -> Promise<ServiceResponse> in
            return self.performServiceRequest(request: request, sessionManager: sessionManager)
        }.map(on: DispatchQueue.global()) { (response: ServiceResponse) -> UpdatedV2Group in

            guard let changeActionsProtoData = response.responseObject as? Data else {
                throw OWSAssertionError("Invalid responseObject.")
            }
            let changeActionsProto = try GroupsV2Protos.parseAndVerifyChangeActionsProto(changeActionsProtoData)

            // GroupsV2 TODO: Instead of loading the group model from the database,
            // we should use exactly the same group model that was used to construct
            // the update request - which should reflect pre-update service state.
            let updatedGroupThread = try self.databaseStorage.write { transaction throws -> TSGroupThread in
                return try self.groupV2Updates.updateGroupWithChangeActions(groupId: groupId,
                                                                            changeActionsProto: changeActionsProto,
                                                                            transaction: transaction)
            }

            // GroupsV2 TODO: Handle conflicts.
            // GroupsV2 TODO: Handle success.
            // GroupsV2 TODO: Propagate failure in a consumable way.
            /*
             If the group change is successfully applied, the service will respond:
             
             200 OK HTTP/2
             Content-Type: application/x-protobuf
             
             {encoded and signed GroupChange}
             
             The response body contains the fully signed and populated group change record, which clients can transmit to group members out of band.
             
             If the group change conflicts with a version that has already been applied (for example, the version in the supplied proto is not current version + 1) , the service will respond:
             
             409 Conflict HTTP/2
             Content-Type: application/x-protobuf
             
             {encoded_current_group_record}
             
             */

            return UpdatedV2Group(groupThread: updatedGroupThread, changeActionsProtoData: changeActionsProtoData)
        }
    }

    private func buildUpdateGroupRequest(localUuid: UUID,
                                         groupV2Params: GroupV2Params,
                                         groupChangeProto: GroupsProtoGroupChangeActions,
                                         sessionManager: AFHTTPSessionManager) -> Promise<NSURLRequest> {

        return retrieveCredentials(localUuid: localUuid)
            .map(on: DispatchQueue.global()) { (authCredentialMap: [UInt32: AuthCredential]) -> NSURLRequest in
                let redemptionTime = self.daysSinceEpoch
                return try StorageService.buildUpdateGroupRequest(groupChangeProto: groupChangeProto,
                                                                  groupV2Params: groupV2Params,
                                                                  sessionManager: sessionManager,
                                                                  authCredentialMap: authCredentialMap,
                                                                  redemptionTime: redemptionTime)
        }
    }

    // MARK: - Fetch Current Group State

    // GroupsV2 TODO: We should be able to clean this up eventually?
    public func fetchCurrentGroupV2Snapshot(groupModel: TSGroupModel) -> Promise<GroupV2Snapshot> {
        guard groupModel.groupsVersion == .V2 else {
            return Promise(error: OWSAssertionError("Invalid groupsVersion."))
        }
        guard let groupSecretParamsData = groupModel.groupSecretParamsData else {
            return Promise(error: OWSAssertionError("Missing groupSecretParamsData."))
        }

        return self.fetchCurrentGroupV2Snapshot(groupSecretParamsData: groupSecretParamsData)
    }

    public func fetchCurrentGroupV2Snapshot(groupSecretParamsData: Data) -> Promise<GroupV2Snapshot> {
        // GroupsV2 TODO: Should we make sure we have a local profile credential?
        guard let localUuid = tsAccountManager.localUuid else {
            return Promise<GroupV2Snapshot>(error: OWSAssertionError("Missing localUuid."))
        }
        return DispatchQueue.global().async(.promise) { () -> GroupV2Params in
            return try GroupV2Params(groupSecretParamsData: groupSecretParamsData)
        }.then(on: DispatchQueue.global()) { (groupV2Params: GroupV2Params) -> Promise<GroupV2Snapshot> in
            return self.fetchCurrentGroupV2Snapshot(groupV2Params: groupV2Params,
                                                    localUuid: localUuid)
        }.map(on: DispatchQueue.global()) { (groupV2Snapshot: GroupV2Snapshot) -> GroupV2Snapshot in
            // GroupsV2 TODO: Remove this logging.
            Logger.verbose("GroupV2Snapshot: \(groupV2Snapshot.debugDescription)")
            return groupV2Snapshot
        }
    }

    private func fetchCurrentGroupV2Snapshot(groupV2Params: GroupV2Params,
                                             localUuid: UUID) -> Promise<GroupV2Snapshot> {
        let sessionManager = self.sessionManager
        return firstly {
            self.retrieveCredentials(localUuid: localUuid)
        }.map(on: DispatchQueue.global()) { (authCredentialMap: [UInt32: AuthCredential]) -> NSURLRequest in

            let redemptionTime = self.daysSinceEpoch
            return try StorageService.buildFetchCurrentGroupV2SnapshotRequest(groupV2Params: groupV2Params,
                                                                              sessionManager: sessionManager,
                                                                              authCredentialMap: authCredentialMap,
                                                                              redemptionTime: redemptionTime)
        }.then(on: DispatchQueue.global()) { (request: NSURLRequest) -> Promise<ServiceResponse> in
            return self.performServiceRequest(request: request, sessionManager: sessionManager)
        }.map(on: DispatchQueue.global()) { (response: ServiceResponse) -> GroupV2Snapshot in
            guard let groupProtoData = response.responseObject as? Data else {
                throw OWSAssertionError("Invalid responseObject.")
            }
            let groupProto = try GroupsProtoGroup.parseData(groupProtoData)
            return try GroupsV2Protos.parse(groupProto: groupProto, groupV2Params: groupV2Params)
        }
    }

    // MARK: - Fetch Group Change Actions

    public func fetchGroupChangeActions(groupSecretParamsData: Data) -> Promise<[GroupV2Change]> {
        // GroupsV2 TODO: Should we make sure we have a local profile credential?
        guard let localUuid = tsAccountManager.localUuid else {
            return Promise(error: OWSAssertionError("Missing localUuid."))
        }
        return DispatchQueue.global().async(.promise) { () -> (Data, GroupV2Params) in
            let groupId = try self.groupId(forGroupSecretParamsData: groupSecretParamsData)
            let groupV2Params = try GroupV2Params(groupSecretParamsData: groupSecretParamsData)
            return (groupId, groupV2Params)
        }.then(on: DispatchQueue.global()) { (groupId: Data, groupV2Params: GroupV2Params) -> Promise<[GroupV2Change]> in
            return self.fetchGroupChangeActions(groupId: groupId,
                                                groupV2Params: groupV2Params,
                                                localUuid: localUuid)
        }
    }

    private func fetchGroupChangeActions(groupId: Data,
                                         groupV2Params: GroupV2Params,
                                         localUuid: UUID) -> Promise<[GroupV2Change]> {
        let sessionManager = self.sessionManager
        return firstly {
            self.retrieveCredentials(localUuid: localUuid)
        }.map(on: DispatchQueue.global()) { (authCredentialMap: [UInt32: AuthCredential]) throws -> NSURLRequest in
            let fromRevision = try self.databaseStorage.read { (transaction) throws -> UInt32 in
                guard let groupThread = TSGroupThread.fetch(groupId: groupId, transaction: transaction) else {
                    // This probably isn't an error and will be handled upstream.
                    throw GroupsV2Error.unknownGroup
                }
                guard groupThread.groupModel.groupsVersion == .V2 else {
                    throw OWSAssertionError("Invalid groupsVersion.")
                }
                return groupThread.groupModel.groupV2Revision
            }
            guard fromRevision > 0 else {
                // GroupsV2 TODO: This is temporary.
                //                There appears to be a bug in the service.
                //                GET /v1/groups/logs/0 always fails.
                throw GroupsV2Error.todo
            }

            let redemptionTime = self.daysSinceEpoch
            return try StorageService.buildFetchGroupChangeActionsRequest(groupV2Params: groupV2Params,
                                                                          fromRevision: fromRevision,
                                                                          sessionManager: sessionManager,
                                                                          authCredentialMap: authCredentialMap,
                                                                          redemptionTime: redemptionTime)
        }.then(on: DispatchQueue.global()) { (request: NSURLRequest) -> Promise<ServiceResponse> in
            return self.performServiceRequest(request: request, sessionManager: sessionManager)
        }.map(on: DispatchQueue.global()) { (response: ServiceResponse) -> [GroupV2Change] in
            guard let groupChangesProtoData = response.responseObject as? Data else {
                throw OWSAssertionError("Invalid responseObject.")
            }
            let groupChangesProto = try GroupsProtoGroupChanges.parseData(groupChangesProtoData)
            return try GroupsV2Protos.parse(groupChangesProto: groupChangesProto, groupV2Params: groupV2Params)
        }
    }

    // MARK: - Perform Request

    private struct ServiceResponse {
        let task: URLSessionDataTask
        let response: URLResponse
        let responseObject: Any?
    }

    // GroupsV2 TODO: We should implement retry for all request methods in this class.
    private func performServiceRequest(request: NSURLRequest,
                                       sessionManager: AFHTTPSessionManager) -> Promise<ServiceResponse> {

        Logger.info("Making group request: \(String(describing: request.httpMethod)) \(request)")

        return Promise { resolver in
            #if TESTABLE_BUILD
            var blockTask: URLSessionDataTask?
            #endif
            let task = sessionManager.dataTask(
                with: request as URLRequest,
                uploadProgress: nil,
                downloadProgress: nil
            ) { response, responseObject, error in

                guard let blockTask = blockTask else {
                    return resolver.reject(OWSAssertionError("Missing blockTask."))
                }

                guard let response = response as? HTTPURLResponse else {
                    Logger.info("Request failed: \(String(describing: request.httpMethod)) \(String(describing: request.url))")

                    guard let error = error else {
                        return resolver.reject(OWSAssertionError("Unexpected response type."))
                    }

                    owsFailDebug("Response error: \(error)")
                    return resolver.reject(error)
                }

                switch response.statusCode {
                case 200:
                    Logger.info("Request succeeded: \(String(describing: request.httpMethod)) \(String(describing: request.url))")
                case 401:
                    Logger.warn("Request not authorized.")
                    return resolver.reject(GroupsV2Error.unauthorized)
                default:
                    #if TESTABLE_BUILD
                    TSNetworkManager.logCurl(for: blockTask)
                    #endif
                    return resolver.reject(OWSAssertionError("Invalid response: \(response.statusCode)"))
                }

                // NOTE: responseObject may be nil; not all group v2 responses have bodies.
                let serviceResponse = ServiceResponse(task: blockTask, response: response, responseObject: responseObject)
                return resolver.fulfill(serviceResponse)
            }
            #if TESTABLE_BUILD
            blockTask = task
            #endif
            task.resume()
        }
    }

    // MARK: - ProfileKeyCredentials

    public func loadProfileKeyCredentialData(for uuids: [UUID]) -> Promise<ProfileKeyCredentialMap> {

        // 1. Use known credentials, where possible.
        var credentialMap = ProfileKeyCredentialMap()

        var uuidsWithoutCredentials = [UUID]()
        databaseStorage.read { transaction in
            // Skip duplicates.
            for uuid in Set(uuids) {
                do {
                    let address = SignalServiceAddress(uuid: uuid)
                    if let credential = try VersionedProfiles.profileKeyCredential(for: address,
                                                                                   transaction: transaction) {
                        credentialMap[uuid] = credential
                        continue
                    }
                } catch {
                    // GroupsV2 TODO: Should we throw here?
                    owsFailDebug("Error: \(error)")
                }
                uuidsWithoutCredentials.append(uuid)
            }
        }

        // If we already have credentials for all members, no need to fetch.
        guard uuidsWithoutCredentials.count > 0 else {
            return Promise.value(credentialMap)
        }

        // 2. Fetch missing credentials.
        var promises = [Promise<UUID>]()
        for uuid in uuidsWithoutCredentials {
            let address = SignalServiceAddress(uuid: uuid)
            let promise = ProfileFetcherJob.fetchAndUpdateProfilePromise(address: address,
                                                                         mainAppOnly: false,
                                                                         ignoreThrottling: true,
                                                                         fetchType: .versioned)
                .map(on: DispatchQueue.global()) { (_: SignalServiceProfile) -> (UUID) in
                    // Ideally we'd pull the credential off of SignalServiceProfile here,
                    // but the credential response needs to be parsed and verified
                    // which requires the VersionedProfileRequest.
                    return uuid
            }
            promises.append(promise)
        }
        return when(fulfilled: promises)
            .map(on: DispatchQueue.global()) { _ in
                // Since we've just successfully fetched versioned profiles
                // for all of the UUIDs without credentials, we _should_ be
                // able to load a credential.
                //
                // If we change how credentials are cleared, we'll need to
                // revisit this to avoid races.
                try self.databaseStorage.read { transaction in
                    for uuid in uuids {
                        let address = SignalServiceAddress(uuid: uuid)
                        guard let credential = try VersionedProfiles.profileKeyCredential(for: address,
                                                                                          transaction: transaction) else {
                                                                                            throw OWSAssertionError("Could load credential.")
                        }
                        credentialMap[uuid] = credential
                    }
                }

                return credentialMap
        }
    }

    public func hasProfileKeyCredential(for address: SignalServiceAddress,
                                        transaction: SDSAnyReadTransaction) -> Bool {
        do {
            return try VersionedProfiles.profileKeyCredential(for: address,
                                                              transaction: transaction) != nil
        } catch {
            owsFailDebug("Error: \(error)")
            return false
        }
    }

    @objc
    public func tryToEnsureProfileKeyCredentialsObjc(for addresses: [SignalServiceAddress]) -> AnyPromise {
        return AnyPromise(tryToEnsureProfileKeyCredentials(for: addresses))
    }

    // When creating (or modifying) a v2 group, we need profile key
    // credentials for all members.  This method tries to find members
    // with known UUIDs who are missing profile key credentials and
    // then tries to get those credentials if possible.
    //
    // This is particularly important when we create a new group, since
    // one of the first things we do is decide whether to create a v1
    // or v2 group.  We have to create a v1 group unless we know the
    // uuid and profile key credential for all members.
    public func tryToEnsureProfileKeyCredentials(for addresses: [SignalServiceAddress]) -> Promise<Void> {
        guard FeatureFlags.versionedProfiledFetches else {
            return Promise.value(())
        }

        var uuidsWithoutProfileKeyCredentials = [UUID]()
        databaseStorage.read { transaction in
            for address in addresses {
                guard let uuid = address.uuid else {
                    // If we don't know the user's UUID, there's no point in
                    // trying to get their credential.
                    continue
                }
                guard !self.hasProfileKeyCredential(for: address, transaction: transaction) else {
                    // If we already have the credential, there's no work to do.
                    continue
                }
                uuidsWithoutProfileKeyCredentials.append(uuid)
            }
        }
        guard uuidsWithoutProfileKeyCredentials.count > 0 else {
            return Promise.value(())
        }

        var promises = [Promise<SignalServiceProfile>]()
        for uuid in uuidsWithoutProfileKeyCredentials {
            let address = SignalServiceAddress(uuid: uuid)
            promises.append(ProfileFetcherJob.fetchAndUpdateProfilePromise(address: address,
                                                                           mainAppOnly: false,
                                                                           ignoreThrottling: true,
                                                                           shouldUpdateProfile: true,
                                                                           fetchType: .versioned))
        }
        return when(fulfilled: promises).asVoid()
    }

    // MARK: - AuthCredentials

    // GroupsV2 TODO: Can we persist and reuse credentials?
    // GroupsV2 TODO: Reorganize this code.
    private func retrieveCredentials(localUuid: UUID) -> Promise<[UInt32: AuthCredential]> {

        let today = self.daysSinceEpoch
        let todayPlus7 = today + 7
        let request = OWSRequestFactory.groupAuthenticationCredentialRequest(fromRedemptionDays: today,
                                                                             toRedemptionDays: todayPlus7)
        return networkManager.makePromise(request: request)
            .map(on: DispatchQueue.global()) { (_: URLSessionDataTask, responseObject: Any?) -> [UInt32: AuthCredential] in
                let temporalCredentials = try self.parseCredentialResponse(responseObject: responseObject)
                let localZKGUuid = try localUuid.asZKGUuid()
                let serverPublicParams = try GroupsV2Protos.serverPublicParams()
                let clientZkAuthOperations = ClientZkAuthOperations(serverPublicParams: serverPublicParams)
                var credentialMap = [UInt32: AuthCredential]()
                for temporalCredential in temporalCredentials {
                    // Verify the credentials.
                    let authCredential: AuthCredential = try clientZkAuthOperations.receiveAuthCredential(uuid: localZKGUuid,
                                                                                                          redemptionTime: temporalCredential.redemptionTime,
                                                                                                          authCredentialResponse: temporalCredential.authCredentialResponse)
                    credentialMap[temporalCredential.redemptionTime] = authCredential
                }
                return credentialMap
        }
    }

    private struct TemporalCredential {
        let redemptionTime: UInt32
        let authCredentialResponse: AuthCredentialResponse
    }

    private func parseCredentialResponse(responseObject: Any?) throws -> [TemporalCredential] {
        guard let responseObject = responseObject else {
            throw OWSAssertionError("Missing response.")
        }

        guard let params = ParamParser(responseObject: responseObject) else {
            throw OWSAssertionError("invalid response: \(String(describing: responseObject))")
        }
        guard let credentials: [Any] = try params.required(key: "credentials") else {
            throw OWSAssertionError("Missing or invalid credentials.")
        }
        var temporalCredentials = [TemporalCredential]()
        for credential in credentials {
            guard let credentialParser = ParamParser(responseObject: credential) else {
                throw OWSAssertionError("invalid credential: \(String(describing: credential))")
            }
            guard let redemptionTime: UInt32 = try credentialParser.required(key: "redemptionTime") else {
                throw OWSAssertionError("Missing or invalid redemptionTime.")
            }
            let responseData: Data = try credentialParser.requiredBase64EncodedData(key: "credential")
            let response = try AuthCredentialResponse(contents: [UInt8](responseData))

            temporalCredentials.append(TemporalCredential(redemptionTime: redemptionTime, authCredentialResponse: response))
        }
        return temporalCredentials
    }

    // MARK: - Change Set

    public func buildChangeSet(from oldGroupModel: TSGroupModel,
                               to newGroupModel: TSGroupModel,
                               transaction: SDSAnyReadTransaction) throws -> GroupsV2ChangeSet {
        let changeSet = try GroupsV2ChangeSetImpl(for: oldGroupModel)
        try changeSet.buildChangeSet(from: oldGroupModel, to: newGroupModel,
                                     transaction: transaction)
        return changeSet
    }

    // MARK: - Protos

    public func buildGroupContextV2Proto(groupModel: TSGroupModel,
                                         changeActionsProtoData: Data?) throws -> SSKProtoGroupContextV2 {
        return try GroupsV2Protos.buildGroupContextV2Proto(groupModel: groupModel, changeActionsProtoData: changeActionsProtoData)
    }

    public func parseAndVerifyChangeActionsProto(_ changeProtoData: Data) throws -> GroupsProtoGroupChangeActions {
        return try GroupsV2Protos.parseAndVerifyChangeActionsProto(changeProtoData)
    }

    // MARK: - Profiles

    public func reuploadLocalProfilePromise() -> Promise<Void> {
        guard FeatureFlags.versionedProfiledUpdate else {
            return Promise(error: OWSAssertionError("Versioned profiles are not enabled."))
        }
        return self.profileManager.reuploadLocalProfilePromise()
    }

    // MARK: - Groups Secrets

    public func generateGroupSecretParamsData() throws -> Data {
        let groupSecretParams = try GroupSecretParams.generate()
        let bytes = groupSecretParams.serialize()
        return bytes.asData
    }

    public func groupSecretParamsData(forMasterKeyData masterKeyData: Data) throws -> Data {
        let groupMasterKey = try GroupMasterKey(contents: [UInt8](masterKeyData))
        let groupSecretParams = try GroupSecretParams.deriveFromMasterKey(groupMasterKey: groupMasterKey)
        return groupSecretParams.serialize().asData
    }

    public func groupId(forGroupSecretParamsData groupSecretParamsData: Data) throws -> Data {
        let groupSecretParams = try GroupSecretParams(contents: [UInt8](groupSecretParamsData))
        return try groupSecretParams.getPublicParams().getGroupIdentifier().serialize().asData
    }

    public func groupV2ContextInfo(forMasterKeyData masterKeyData: Data?) throws -> GroupV2ContextInfo {
        guard let masterKeyData = masterKeyData else {
            throw OWSAssertionError("Missing masterKeyData.")
        }
        let groupSecretParamsData = try self.groupSecretParamsData(forMasterKeyData: masterKeyData)
        let groupId = try self.groupId(forGroupSecretParamsData: groupSecretParamsData)
        guard GroupManager.isValidGroupId(groupId, groupsVersion: .V2) else {
            throw OWSAssertionError("Invalid groupId.")
        }
        return GroupV2ContextInfo(masterKeyData: masterKeyData,
                                  groupSecretParamsData: groupSecretParamsData,
                                  groupId: groupId)
    }

    // MARK: - Utils

    private var daysSinceEpoch: UInt32 {
        let msSinceEpoch = NSDate.ows_millisecondTimeStamp()
        let daysSinceEpoch = UInt32(msSinceEpoch / kDayInMs)
        return daysSinceEpoch
    }

    private func uuids(for addresses: [SignalServiceAddress]) -> [UUID] {
        var uuids = [UUID]()
        for address in addresses {
            guard let uuid = address.uuid else {
                owsFailDebug("Missing UUID.")
                continue
            }
            uuids.append(uuid)
        }
        return uuids
    }
}
