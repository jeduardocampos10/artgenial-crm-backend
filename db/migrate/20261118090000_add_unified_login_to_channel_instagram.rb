# frozen_string_literal: true

class AddUnifiedLoginToChannelInstagram < ActiveRecord::Migration[7.1]
  def up
    add_column :channel_instagram, :auth_mode, :string, default: 'instagram_login', null: false, if_not_exists: true
    add_column :channel_instagram, :client_business_id, :string, if_not_exists: true
    add_column :channel_instagram, :login_config_id, :string, if_not_exists: true

    change_column :channel_instagram, :access_token, :text
    change_column_null :channel_instagram, :expires_at, true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Unified tokens may exceed varchar limits and may not expire'
  end
end
