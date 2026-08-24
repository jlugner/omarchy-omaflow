# frozen_string_literal: true

module Omaflow
  module Vocabulary
    TRIGGERS = %w[manual time monitor-connected monitor-disconnected wifi-connected wifi-disconnected power-source].freeze
    CONDITIONS = %w[time-between weekday on-power monitor-present on-ssid].freeze
    ACTIONS = %w[theme dnd nightlight stay-awake launch workspace audio-output webhook notify].freeze
    WEEKDAYS = %w[mon tue wed thu fri sat sun].freeze
    WEBHOOK_FORMATS = %w[json slack discord ntfy raw].freeze
    RULE_FIELDS = %w[schemaVersion id name enabled trigger conditions actions cooldownSeconds source createdBy createdAt].freeze
  end
end
