defmodule JidoManagedAgentsWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use JidoManagedAgentsWeb, :verified_routes

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {JidoManagedAgentsWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    socket =
      socket
      |> AshAuthentication.Phoenix.LiveSession.assign_new_resources(session)
      |> JidoManagedAgents.AshActor.assign_socket_actor()

    {:cont, socket}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, JidoManagedAgents.AshActor.assign_socket_actor(socket)}
    else
      {:cont,
       socket |> assign(:current_user, nil) |> JidoManagedAgents.AshActor.assign_socket_actor()}
    end
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, JidoManagedAgents.AshActor.assign_socket_actor(socket)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/console")}
    else
      {:cont,
       socket |> assign(:current_user, nil) |> JidoManagedAgents.AshActor.assign_socket_actor()}
    end
  end
end
