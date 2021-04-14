/*
 Copyright 2020 Adobe. All rights reserved.
 This file is licensed to you under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License. You may obtain a copy
 of the License at http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software distributed under
 the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
 OF ANY KIND, either express or implied. See the License for the specific language
 governing permissions and limitations under the License.
 */

import AEPCore
import AEPServices
import Foundation

@objc(AEPMobileMessaging)
public class Messaging: NSObject, Extension {
    public static var extensionVersion: String = MessagingConstants.EXTENSION_VERSION
    public var name = MessagingConstants.EXTENSION_NAME
    public var friendlyName = MessagingConstants.FRIENDLY_NAME
    public var metadata: [String: String]?
    public var runtime: ExtensionRuntime

    // =================================================================================================================

    // MARK: - ACPExtension protocol methods

    // =================================================================================================================
    public required init?(runtime: ExtensionRuntime) {
        self.runtime = runtime
        super.init()
    }

    public func onRegistered() {
        // register listener for configuration response event
        registerListener(type: EventType.configuration,
                         source: EventSource.responseContent,
                         listener: handleConfigurationResponse)

        // register listener for set push identifier event
        registerListener(type: EventType.genericIdentity,
                         source: EventSource.requestContent,
                         listener: handleProcessEvent)

        // register listener for Messaging request content event
        registerListener(type: MessagingConstants.EventType.messaging,
                         source: EventSource.requestContent,
                         listener: handleProcessEvent)
    }

    public func onUnregistered() {
        print("Extension unregistered from MobileCore: \(MessagingConstants.FRIENDLY_NAME)")
    }

    public func readyForEvent(_ event: Event) -> Bool {
        guard let configurationSharedState = getSharedState(extensionName: MessagingConstants.SharedState.Configuration.NAME, event: event) else {
            Log.debug(label: MessagingConstants.LOG_TAG, "Event processing is paused, waiting for valid configuration - '\(event.id.uuidString)'.")
            return false
        }

        // hard dependency on identity module for ecid
        guard let identitySharedState = getSharedState(extensionName: MessagingConstants.SharedState.Identity.NAME, event: event) else {
            Log.debug(label: MessagingConstants.LOG_TAG, "Event processing is paused, waiting for valid shared state from identity - '\(event.id.uuidString)'.")
            return false
        }

        return configurationSharedState.status == .set && identitySharedState.status == .set
    }

    /// Based on the configuration response check for privacy status stop events if opted out
    /// - Parameters:
    ///     - event: configuration response event
    func handleConfigurationResponse(_ event: Event) {
        guard let privacyStatusValue = event.globalPrivacyStatus else {
            Log.warning(label: MessagingConstants.LOG_TAG, "Privacy status does not exists. All requests to sync with profile will fail.")
            return
        }

        let privacyStatus = PrivacyStatus(rawValue: privacyStatusValue)
        if privacyStatus != PrivacyStatus.optedIn {
            Log.debug(label: MessagingConstants.LOG_TAG, "Privacy is not optedIn, stopping the events processing.")
            stopEvents()
        }

        if privacyStatus == PrivacyStatus.optedIn {
            Log.debug(label: MessagingConstants.LOG_TAG, "Privacy is optedIn, starting the events processing.")
            startEvents()
        }
    }

    /// Processes the events in the event queue in the order they were received.
    ///
    /// A valid Configuration and identity shared state is required for processing events.
    ///
    /// - Parameters:
    ///   - event: An `Event` to be processed
    func handleProcessEvent(_ event: Event) {
        if event.data == nil {
            Log.debug(label: MessagingConstants.LOG_TAG, "Ignoring event with no data - `\(event.id)`.")
            return
        }

        // hard dependency on configuration shared state
        guard let configSharedState = getSharedState(extensionName: MessagingConstants.SharedState.Configuration.NAME, event: event)?.value else {
            Log.debug(label: MessagingConstants.LOG_TAG, "Event processing is paused, waiting for valid configuration - '\(event.id.uuidString)'.")
            return
        }

        // hard dependency on identity module for ecid
        guard let identitySharedState = getSharedState(extensionName: MessagingConstants.SharedState.Identity.NAME, event: event)?.value else {
            Log.debug(label: MessagingConstants.LOG_TAG, "Event processing is paused, waiting for valid shared state from identity - '\(event.id.uuidString)'.")
            return
        }

        if event.isGenericIdentityRequestContentEvent {
            guard let privacyStatus = PrivacyStatus(rawValue: configSharedState[MessagingConstants.SharedState.Configuration.GLOBAL_PRIVACY] as? String ?? "") else {
                Log.warning(label: MessagingConstants.LOG_TAG, "ConfigSharedState has invalid privacy status, Ignoring to process event : '\(event.id.uuidString)'.")
                return
            }

            if privacyStatus == PrivacyStatus.optedIn {
                syncPushToken(configSharedState, identity: identitySharedState, event: event)
            }
            return
        }

        // Check if the event type is `MessagingConstants.EventType.MESSAGING` and
        // eventSource is `EventSource.requestContent` handle processing of the tracking information
        if event.type == MessagingConstants.EventType.messaging,
            event.source == EventSource.requestContent, configSharedState.keys.contains(MessagingConstants.SharedState.Configuration.EXPERIENCE_EVENT_DATASET)
        {
            handleTrackingInfo(event: event, configSharedState)
            return
        }
    }

    /// Sync the push token to adobe experience platform through edge
    private func syncPushToken(_ config: [AnyHashable: Any], identity: [AnyHashable: Any], event: Event) {
        // get ecid from the identity
        guard let ecid = identity[MessagingConstants.SharedState.Identity.MID] as? String else {
            Log.warning(label: MessagingConstants.LOG_TAG, "Cannot process event that does not have a valid ECID - '\(event.id.uuidString)'.")
            return
        }

        // Get push token from event data
        guard let token = event.token else {
            Log.debug(label: MessagingConstants.LOG_TAG, "Ignoring event with missing or invalid push identifier - '\(event.id.uuidString)'.")
            return
        }

        // Return if the push token is empty
        if token.isEmpty {
            Log.debug(label: MessagingConstants.LOG_TAG, "Ignoring event with missing or invalid push identifier - '\(event.id.uuidString)'.")
            return
        }

        sendPushToken(ecid: ecid, token: token, platform: getPlatform(config: config))
    }

    /// Send an edge event to sync the push notification details with push token
    ///
    /// - Parameters:
    ///   - ecid: Experience cloud id
    ///   - token: Push token for the device
    ///   - platform: `String` denoting the platform `apns` or `apnsSandbox`
    private func sendPushToken(ecid: String, token: String, platform: String) {
        // send the request
        guard let appId: String = Bundle.main.bundleIdentifier else {
            Log.warning(label: MessagingConstants.LOG_TAG, "Failed to sync the push token, App bundle identifier is invalid.")
            return
        }

        // Create the profile experience event to send the push notification details with push token to profile
        let profileEventData: [String: Any] = [
            MessagingConstants.PushNotificationDetails.PUSH_NOTIFICATION_DETAILS: [
                [MessagingConstants.PushNotificationDetails.APP_ID: appId,
                 MessagingConstants.PushNotificationDetails.TOKEN: token,
                 MessagingConstants.PushNotificationDetails.PLATFORM: platform,
                 MessagingConstants.PushNotificationDetails.DENYLISTED: false,
                 MessagingConstants.PushNotificationDetails.IDENTITY: [
                     MessagingConstants.PushNotificationDetails.NAMESPACE: [
                         MessagingConstants.PushNotificationDetails.CODE: MessagingConstants.PushNotificationDetails.JsonValues.ECID,
                     ], MessagingConstants.PushNotificationDetails.ID: ecid,
                 ]],
            ],
        ]

        // Creating xdm edge event data
        let xdmEventData: [String: Any] = [MessagingConstants.XDMDataKeys.DATA: profileEventData]
        // Creating xdm edge event with request content source type
        let event = Event(name: MessagingConstants.EventName.MESSAGING_PUSH_PROFILE_EDGE_EVENT,
                          type: EventType.edge,
                          source: EventSource.requestContent,
                          data: xdmEventData)
        MobileCore.dispatch(event: event)
    }

    /// Sends an experience event to the platform sdk for tracking the notification click-throughs
    /// - Parameters:
    ///   - event: The triggering event with the click through data
    ///   - config: configuration data
    /// - Returns: A boolean explaining whether the handling of tracking info was successful or not
    private func handleTrackingInfo(event: Event, _ config: [AnyHashable: Any]) {
        guard let expEventDatasetId = config[MessagingConstants.SharedState.Configuration.EXPERIENCE_EVENT_DATASET] as? String else {
            Log.warning(label: MessagingConstants.LOG_TAG, "Experience event dataset ID is invalid.")
            return
        }

        // Get the schema and convert to xdm dictionary
        guard var xdmMap = getXdmData(event: event, config: config) else {
            Log.warning(label: MessagingConstants.LOG_TAG, "Unable to track information. Schema generation from eventData failed.")
            return
        }

        // Add application specific tracking data
        let applicationOpened = event.applicationOpened
        xdmMap = addApplicationData(applicationOpened: applicationOpened, xdmData: xdmMap)

        // Add Adobe specific tracking data
        xdmMap = addAdobeData(event: event, xdmDict: xdmMap)

        // Creating xdm edge event data
        let xdmEventData: [String: Any] = [MessagingConstants.XDMDataKeys.XDM: xdmMap, MessagingConstants.XDMDataKeys.META: [
            MessagingConstants.XDMDataKeys.COLLECT: [
                MessagingConstants.XDMDataKeys.DATASET_ID: expEventDatasetId,
            ],
        ]]
        // Creating xdm edge event with request content source type
        let event = Event(name: MessagingConstants.EventName.MESSAGING_PUSH_TRACKING_EDGE_EVENT,
                          type: EventType.edge,
                          source: EventSource.requestContent,
                          data: xdmEventData)
        MobileCore.dispatch(event: event)
    }

    /// Adding CJM specific data to tracking information schema map.
    /// - Parameters:
    ///  - event: `Event` with Adobe cjm tracking information
    ///  - xdmDict: `[AnyHashable: Any]` which is updated with the cjm tracking information.
    private func addAdobeData(event: Event, xdmDict: [String: Any]) -> [String: Any] {
        var xdmDictResult = xdmDict
        guard let _ = event.adobeXdm else {
            Log.warning(label: MessagingConstants.LOG_TAG, "Failed to update Adobe tracking information. Adobe data is invalid.")
            return xdmDictResult
        }

        // Check if the json has the required keys
        var mixins: [String: Any]? = event.mixins
        // If key `mixins` is not present check for cjm
        if mixins == nil {
            // check if CJM key is not present return the orginal xdmDict
            guard let cjm: [String: Any] = event.cjm else {
                Log.warning(label: MessagingConstants.LOG_TAG,
                            "Failed to send Adobe data with the tracking data, Adobe data is malformed")
                return xdmDictResult
            }
            mixins = cjm
        }

        // Add all the key and value pair to xdmDictResult
        xdmDictResult += mixins ?? [:]

        // Check if the xdm data provided by the customer is using cjm for tracking
        // Check if both `MessagingConstant.AdobeTrackingKeys.EXPERIENCE` and `MessagingConstant.AdobeTrackingKeys.CUSTOMER_JOURNEY_MANAGEMENT` exists
        if var experienceDict = xdmDictResult[MessagingConstants.AdobeTrackingKeys.EXPERIENCE] as? [String: Any] {
            if var cjmDict = experienceDict[MessagingConstants.AdobeTrackingKeys.CUSTOMER_JOURNEY_MANAGEMENT] as? [String: Any] {
                // Adding Message profile and push channel context to CUSTOMER_JOURNEY_MANAGEMENT
                guard let messageProfile = convertStringToDictionary(text: MessagingConstants.AdobeTrackingKeys.MESSAGE_PROFILE_JSON) else {
                    Log.warning(label: MessagingConstants.LOG_TAG,
                                "Failed to update Adobe tracking information. Messaging profile data is malformed.")
                    return xdmDictResult
                }
                // Merging the dictionary
                cjmDict += messageProfile
                experienceDict[MessagingConstants.AdobeTrackingKeys.CUSTOMER_JOURNEY_MANAGEMENT] = cjmDict
                xdmDictResult[MessagingConstants.AdobeTrackingKeys.EXPERIENCE] = experienceDict
            }
        } else {
            Log.warning(label: MessagingConstants.LOG_TAG, "Failed to send cjm xdm data with the tracking, required keys are missing.")
        }
        return xdmDictResult
    }

    /// Adding application data based on the application opened or not
    /// - Parameters:
    ///   - applicationOpened: `Bool` stating whether the application is opened or not
    ///   - xdmData: `[AnyHashable: Any]` xdm data in which application data needs to be added
    /// - Returns: `[String: Any]` which conatins the application data
    private func addApplicationData(applicationOpened: Bool, xdmData: [String: Any]) -> [String: Any] {
        var xdmDataResult = xdmData
        xdmDataResult[MessagingConstants.AdobeTrackingKeys.APPLICATION] =
            [MessagingConstants.AdobeTrackingKeys.LAUNCHES:
                [MessagingConstants.AdobeTrackingKeys.LAUNCHES_VALUE: applicationOpened ? 1 : 0]]
        return xdmDataResult
    }

    /// Creates the xdm schema from event data
    /// - Parameters:
    ///   - event: `Event` with push notification tracking information
    ///   - config: `[AnyHashable: Any]` with configuration informations
    /// - Returns: `[String: Any]?` which contains the xdm data
    private func getXdmData(event: Event, config: [AnyHashable: Any]) -> [String: Any]? {
        guard let eventType = event.eventType else {
            Log.warning(label: MessagingConstants.LOG_TAG, "eventType is nil")
            return nil
        }
        let messageId = event.messagingId
        let actionId = event.actionId

        if eventType.isEmpty == true || messageId == nil || messageId?.isEmpty == true {
            Log.trace(label: MessagingConstants.LOG_TAG, "Unable to track information. EventType or MessageId received is null.")
            return nil
        }

        var xdmDict: [String: Any] = [MessagingConstants.XDMDataKeys.EVENT_TYPE: eventType]
        var pushNotificationTrackingDict: [String: Any] = [:]
        var customActionDict: [String: Any] = [:]
        if actionId != nil {
            customActionDict[MessagingConstants.XDMDataKeys.ACTION_ID] = actionId
            pushNotificationTrackingDict[MessagingConstants.XDMDataKeys.CUSTOM_ACTION] = customActionDict
        }
        pushNotificationTrackingDict[MessagingConstants.XDMDataKeys.PUSH_PROVIDER_MESSAGE_ID] = messageId
        pushNotificationTrackingDict[MessagingConstants.XDMDataKeys.PUSH_PROVIDER] = getPlatform(config: config)
        xdmDict[MessagingConstants.XDMDataKeys.PUSH_NOTIFICATION_TRACKING] = pushNotificationTrackingDict

        return xdmDict
    }

    /// Helper methods

    /// Converts a dictionary string to dictionary object
    /// - Parameters:
    ///   - text: String dictionary which needs to be converted
    /// - Returns: Dictionary
    private func convertStringToDictionary(text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8) {
            do {
                let json = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String: Any]
                return json
            } catch {
                print("Unexpected error: \(error).")
                return nil
            }
        }
        return nil
    }

    /// Get platform based on the `messaging.useSandbox` config value
    /// - Parameters:
    ///     - config: `[AnyHashable: Any]` with platform informations
    private func getPlatform(config: [AnyHashable: Any]) -> String {
        return config[MessagingConstants.SharedState.Configuration.USE_SANDBOX] as? Bool ?? false
            ? MessagingConstants.PushNotificationDetails.JsonValues.APNS_SANDBOX
            : MessagingConstants.PushNotificationDetails.JsonValues.APNS
    }
}

/// Use to merge 2 dictionaries together
func += <K, V>(left: inout [K: V], right: [K: V]) {
    left.merge(right) { _, new in new }
}