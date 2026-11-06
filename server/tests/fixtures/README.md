The EC key pair here is deliberately public and used only by local APNs request
signing/verification tests. It was generated for these tests and is not registered
with Apple. Never configure the running server with this key; use your own private
Apple-issued APNs `.p8` file outside the repository.
