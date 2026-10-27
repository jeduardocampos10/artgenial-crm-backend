module RequestExceptionHandler
  extend ActiveSupport::Concern

  included do
    rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid
    rescue_from ContactMergeAction::MergeBlocked, with: :render_contact_merge_blocked
  end

  private

  def render_contact_merge_blocked(_exception)
    message = 'Contact identification requires review before these contacts can be merged'
    if respond_to?(:error_response)
      error_response(ApiErrorCodes::VALIDATION_ERROR, message, status: :unprocessable_entity)
    else
      render json: { error: message }, status: :unprocessable_entity
    end
  end

  def handle_with_exception
    yield
  rescue ActiveRecord::RecordNotFound => e
    log_handled_error(e)
    render_not_found_error('Resource could not be found')
  rescue Pundit::NotAuthorizedError => e
    log_handled_error(e)
    render_unauthorized('You are not authorized to do this action')
  rescue ActionController::ParameterMissing => e
    log_handled_error(e)
    render_could_not_create_error(e.message)
  ensure
    # to address the thread variable leak issues in Puma/Thin webserver
    Current.reset
  end

  def render_unauthorized(message)
    if respond_to?(:error_response)
      error_response(ApiErrorCodes::UNAUTHORIZED, message, status: :unauthorized)
    else
    render json: { error: message }, status: :unauthorized
    end
  end

  def render_not_found_error(message)
    if respond_to?(:error_response)
      error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, message, status: :not_found)
    else
    render json: { error: message }, status: :not_found
    end
  end

  def render_could_not_create_error(message)
    if respond_to?(:error_response)
      error_response(ApiErrorCodes::VALIDATION_ERROR, message, status: :unprocessable_entity)
    else
    render json: { error: message }, status: :unprocessable_entity
    end
  end

  def render_payment_required(message)
    if respond_to?(:error_response)
      error_response(ApiErrorCodes::LIMIT_EXCEEDED, message, status: :payment_required)
    else
    render json: { error: message }, status: :payment_required
    end
  end

  def render_internal_server_error(message)
    if respond_to?(:error_response)
      error_response(ApiErrorCodes::INTERNAL_ERROR, message, status: :internal_server_error)
    else
    render json: { error: message }, status: :internal_server_error
    end
  end

  def render_record_invalid(exception)
    log_handled_error(exception)
    if respond_to?(:error_response)
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        exception.record.errors.full_messages.join(', '),
        details: exception.record.errors.attribute_names,
        status: :unprocessable_entity
      )
    else
    render json: {
      message: exception.record.errors.full_messages.join(', '),
      attributes: exception.record.errors.attribute_names
    }, status: :unprocessable_entity
    end
  end

  def render_error_response(exception)
    log_handled_error(exception)
    if respond_to?(:error_response)
      # Convert CustomException to standardized error response format
      error_code = exception.class.name.demodulize.underscore.upcase
      error_response(
        error_code,
        exception.message,
        details: exception.respond_to?(:data) ? exception.data : nil,
        status: exception.http_status
      )
    else
      error_response(ApiErrorCodes::INTERNAL_ERROR, exception.message, details: exception.data, status: exception.http_status)
    end
  end

  def log_handled_error(exception)
    logger.info("Handled error: #{exception.inspect}")
  end
end
