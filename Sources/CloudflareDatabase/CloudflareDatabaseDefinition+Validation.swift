extension CloudflareDatabaseDefinition {
    /// Validates platform restrictions before Cloudflare storage opens.
    public func validateHostingCapabilities()
        throws(CloudflareDatabaseConfigurationError) {
        try CloudflareDatabaseHostingCapabilityValidator.validate(self)
    }
}
