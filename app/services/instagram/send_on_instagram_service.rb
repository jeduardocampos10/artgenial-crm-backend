class Instagram::SendOnInstagramService < Instagram::BaseSendService
  private

  def channel_class
    Channel::Instagram
  end

  # Deliver a message with the given payload.
  # https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/messaging-api
  def send_message(message_content)
    access_token = channel.access_token
    instagram_id = channel.instagram_id.presence || 'me'

    response = HTTParty.post(
      "#{channel.graph_api_base_url}/#{instagram_id}/messages",
      body: message_content,
      headers: { 'Authorization' => "Bearer #{access_token}" }
    )

    process_response(response, message_content)
  end

  def merge_human_agent_tag(params)
    global_config = GlobalConfig.get('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT')

    return params unless global_config['ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT']

    params[:messaging_type] = 'MESSAGE_TAG'
    params[:tag] = 'HUMAN_AGENT'
    params
  end
end
