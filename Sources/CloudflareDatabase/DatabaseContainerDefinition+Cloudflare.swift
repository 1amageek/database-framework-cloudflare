import DatabaseWireRuntime

extension DatabaseContainerDefinition {
    /// Validates platform restrictions before Cloudflare storage opens.
    public func validateCloudflareHostingCapabilities()
        throws(CloudflareDatabaseConfigurationError) {
        try CloudflareDatabaseHostingCapabilityValidator.validate(self)
    }
}
