class Api::V1::Actions::ContactMergesController < Api::V1::BaseController
  # Merging destroys the mergee contact irreversibly, so it demands the
  # delete-level grant rather than plain update.
  require_permissions({
    create: 'contacts.delete'
  })

  before_action :set_base_contact, only: [:create]
  before_action :set_mergee_contact, only: [:create]

  def create
    contact_merge_action = ContactMergeAction.new(
      base_contact: @base_contact,
      mergee_contact: @mergee_contact
    )
    contact_merge_action.perform
  rescue ContactMergeAction::MergeBlocked => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_base_contact
    @base_contact = contacts.find(params[:base_contact_id])
  end

  def set_mergee_contact
    @mergee_contact = contacts.find(params[:mergee_contact_id])
  end

  def contacts
    @contacts ||= Contact.all
  end
end
