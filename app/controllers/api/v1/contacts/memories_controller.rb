# frozen_string_literal: true

class Api::V1::Contacts::MemoriesController < Api::V1::Contacts::BaseController
  DEFAULT_PAGE_SIZE = 20
  MAX_PAGE_SIZE = 100

  require_permissions({ index: 'contacts.read' })
  # Contacts::BaseController loads a contact before child callbacks by default.
  # For this endpoint permission must be evaluated first so a denied request
  # cannot distinguish an existing contact from a missing one.
  skip_before_action :ensure_contact
  skip_before_action :check_index_permission!, only: :index
  before_action :check_index_permission!, only: :index
  before_action :load_contact, only: :index

  # Memory is intentionally a read-only Customer 360 surface. The nested contact
  # relation prevents a caller from supplying a global MemoryRecord scope.
  def index
    memories = @contact.memory_records
                       .includes(:memory_evidences)
                       .order(observed_at: :desc, id: :desc)
                       .page(current_page)
                       .per(page_size)

    paginated_response(
      data: MemoryRecordSerializer.serialize_collection(memories),
      collection: memories,
      message: 'Contact memories retrieved successfully'
    )
  end

  private

  def load_contact
    @contact = Contact.find(params[:contact_id])
  end

  def current_page
    normalized_positive_integer(params[:page], default: 1)
  end

  def page_size
    requested_size = params[:pageSize].presence || params[:page_size].presence || params[:per_page].presence
    [normalized_positive_integer(requested_size, default: DEFAULT_PAGE_SIZE), MAX_PAGE_SIZE].min
  end

  # `to_i` turns malformed values into zero. Treating zero as one would make a
  # typo such as `pageSize=large` silently select a non-standard one-item page.
  # Keep the documented defaults for absent, zero, negative and malformed input.
  def normalized_positive_integer(value, default:)
    parsed = Integer(value, exception: false)
    parsed&.positive? ? parsed : default
  end
end
