open Lwt

let _ = Tls_lwt.rng_init ()

module Client = struct
  let connect ?src host sa =
    let fd = Lwt_unix.socket (Unix.domain_of_sockaddr sa) Unix.SOCK_STREAM 0 in
    let () =
      match src with
      | None -> ()
      | Some src_sa -> Lwt_unix.bind fd src_sa
    in
    X509_lwt.authenticator `No_authentication_I'M_STUPID >>= fun authenticator ->
    let config = Tls.Config.client ~authenticator () in
    Lwt_unix.connect fd sa >>= fun () ->
    Tls_lwt.Unix.client_of_fd config ~host fd >|= fun t ->
    let ic, oc = Tls_lwt.of_t t in
    (fd, ic, oc)
end

module Server = struct
  let listen nconn sa =
    let fd = Lwt_unix.socket (Unix.domain_of_sockaddr sa) Unix.SOCK_STREAM 0 in
    Lwt_unix.(setsockopt fd SO_REUSEADDR true);
    Lwt_unix.bind fd sa;
    Lwt_unix.listen fd nconn;
    fd

  let accept config s =
    Lwt_unix.accept s >>= fun (fd, sa) ->
    Tls_lwt.Unix.server_of_fd config fd >|= fun t ->
    let ic, oc = Tls_lwt.of_t t in
    (fd, ic, oc)

  let process_accept ~timeout callback (cfd, ic, oc) =
    let c = callback cfd ic oc in
    let events = match timeout with
      | None -> [c]
      | Some t -> [c; (Lwt_unix.sleep (float_of_int t)) ] in
    Lwt.pick events

  let init ?(nconn=20) ~certfile ~keyfile
      ?(stop = fst (Lwt.wait ())) ?timeout sa callback =
    X509_lwt.private_of_pems ~cert:certfile ~priv_key:keyfile >>= fun certificate ->
    let config = Tls.Config.server ~certificate () in
    let s = listen nconn sa in
    let cont = ref true in
    async (fun () ->
      stop >>= fun () ->
      cont := false;
      return_unit
    );
    let rec loop () =
      if not !cont then return_unit
      else (
        Lwt.catch
          (fun () -> accept config s >>= process_accept ~timeout callback)
          (function
            | Lwt.Canceled -> cont := false; return ()
            | _ -> return ())
        >>= loop
      )
    in
    loop ()
end
