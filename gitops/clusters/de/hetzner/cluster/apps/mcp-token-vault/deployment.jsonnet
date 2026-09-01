// The vault Deployment, as Jsonnet so ArgoCD's build environment can feed
// it: the image is a rolling :main tag, and the image-refresh annotation is
// the app source's rendered revision (TLA below, wired from
// $ARGOCD_APP_REVISION_SHORT in app.yaml) -- every sync at a new revision
// changes the pod template, forcing a restart and a fresh :main pull. No
// manual annotation bumps. Plain YAML manifests get no build-env
// substitution in ArgoCD (only Helm/Jsonnet/Kustomize/CMPs do), which is
// why this one file is Jsonnet; everything else in the app dir stays plain
// YAML.
function(revision) [
  {
    apiVersion: 'apps/v1',
    kind: 'Deployment',
    metadata: {
      name: 'mcp-token-vault',
      namespace: 'mcp-token-vault',
      labels: { 'app.kubernetes.io/name': 'mcp-token-vault' },
    },
    spec: {
      replicas: 1,
      selector: { matchLabels: { 'app.kubernetes.io/name': 'mcp-token-vault' } },
      template: {
        metadata: {
          labels: { 'app.kubernetes.io/name': 'mcp-token-vault' },
          annotations: {
            // Rolling tag: CI (mcp-token-vault workflow) rebuilds :main on
            // every push touching services/mcp-token-vault. Pin to a sha-
            // tag if a change ever needs to be held back.
            'willpxxr.com/image-refresh': revision,
          },
        },
        spec: {
          automountServiceAccountToken: false,
          containers: [
            {
              name: 'vault',
              image: 'ghcr.io/willpxxr/mcp-token-vault:main',
              imagePullPolicy: 'Always',
              ports: [
                { name: 'proxy-linear', containerPort: 8081 },
                { name: 'admin', containerPort: 9090 },
                { name: 'oauth', containerPort: 9091 },
                { name: 'authz', containerPort: 9092 },
              ],
              env: [
                { name: 'RUST_LOG', value: 'info' },
                { name: 'DATABASE_URL', valueFrom: { secretKeyRef: { name: 'mcp-token-vault', key: 'db_url' } } },
                { name: 'VAULT_ENCRYPTION_KEY', valueFrom: { secretKeyRef: { name: 'mcp-token-vault', key: 'encryption_key' } } },
                // Built-in postgres role connection; the vault uses it at
                // startup to bootstrap/reconcile its own least-privilege
                // role (WEP-0006).
                { name: 'ADMIN_DATABASE_URL', valueFrom: { secretKeyRef: { name: 'mcp-token-vault', key: 'admin_url' } } },
                { name: 'ADMIN_PORT', value: '9090' },
                { name: 'OAUTH_PORT', value: '9091' },
                { name: 'AUTHZ_PORT', value: '9092' },
                // Public hostname the Gateway serves for the browser-facing
                // credential UI (/oauth/<provider>/start); exposed by
                // httproute-ui.yaml behind the Auth0 SecurityPolicy.
                { name: 'ELICITATION_BASE_URL', value: 'https://tokens.internal.willpxxr.com' },
                { name: 'PROVIDER_LINEAR_UPSTREAM_URL', value: 'https://mcp.linear.app/mcp' },
                // TO VERIFY when creating the Linear OAuth app: confirm the
                // authorize/token endpoints against Linear's OAuth docs.
                { name: 'PROVIDER_LINEAR_TOKEN_URL', value: 'https://api.linear.app/oauth/token' },
                { name: 'PROVIDER_LINEAR_AUTHORIZE_URL', value: 'https://linear.app/oauth/authorize' },
                { name: 'PROVIDER_LINEAR_REDIRECT_URI', value: 'https://tokens.internal.willpxxr.com/cb/oauth/linear/callback' },
                { name: 'PROVIDER_LINEAR_CLIENT_ID', valueFrom: { secretKeyRef: { name: 'linear-mcp-oauth', key: 'client_id' } } },
                { name: 'PROVIDER_LINEAR_CLIENT_SECRET', valueFrom: { secretKeyRef: { name: 'linear-mcp-oauth', key: 'client_secret' } } },
              ],
              livenessProbe: {
                httpGet: { path: '/healthz', port: 9090 },
                initialDelaySeconds: 5,
                periodSeconds: 30,
              },
              readinessProbe: {
                httpGet: { path: '/healthz', port: 9090 },
                initialDelaySeconds: 3,
                periodSeconds: 10,
              },
              resources: {
                requests: { cpu: '100m', memory: '128Mi' },
                limits: { cpu: '500m', memory: '512Mi' },
              },
              securityContext: {
                runAsNonRoot: true,
                readOnlyRootFilesystem: true,
                allowPrivilegeEscalation: false,
                capabilities: { drop: ['ALL'] },
                seccompProfile: { type: 'RuntimeDefault' },
              },
            },
          ],
        },
      },
    },
  },
]
