# frozen_string_literal: true

module Omaflow
  module Vocabulary
    TRIGGERS = %w[
      manual time interval lid-opened lid-closed monitor-connected monitor-disconnected
      app-opened app-closed wifi-connected wifi-disconnected power-source custom
    ].freeze
    CONDITIONS = %w[time-between weekday on-power lid-state monitor-present app-running on-ssid].freeze
    ACTIONS = %w[theme dnd nightlight stay-awake launch workspace audio-output script webhook notify agent].freeze
    AGENT_OPS = %w[close-window focus-window move-window-to-workspace notify].freeze
    WEEKDAYS = %w[mon tue wed thu fri sat sun].freeze
    WEBHOOK_FORMATS = %w[json slack discord ntfy raw].freeze
    RULE_FIELDS = %w[schemaVersion id name enabled trigger conditions actions cooldownSeconds source createdBy createdAt].freeze
  end
end
