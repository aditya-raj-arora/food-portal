# Q2 – Online Food Ordering Portal
### Automated testing and blue-green deployment

## Repository layout

```
food-portal/
├── index.html              Restaurant details, categories, menu, prices, availability, offers
├── styles.css
├── nginx.conf              Serves the site and exposes /healthz
├── Dockerfile
├── deployment-blue.yaml    Blue environment – 3 replicas
├── deployment-green.yaml   Green environment – 3 replicas
├── service.yaml            LIVE NodePort Service (30082) – users
├── service-preview.yaml    PREVIEW NodePort Service (30083) – validation of the idle colour
├── Jenkinsfile
└── tests/smoke-test.sh     Automated tests (sections, prices, availability, assets, release version)
```

**Before you start:** replace `YOUR_DOCKERHUB_USERNAME` in `Jenkinsfile`, `deployment-blue.yaml` and `deployment-green.yaml`.

### How blue-green works here

| Object | Role |
|---|---|
| `food-portal-blue` / `food-portal-green` | Two identical Deployments, each 3 replicas. One serves users, the other is idle. |
| `food-portal` (NodePort 30082) | Live Service. Its selector `version: blue|green` decides which colour receives user traffic. |
| `food-portal-preview` (NodePort 30083) | Points at the idle colour so the new release can be tested before users see it. |

Pipeline: **Checkout → Build Image → Automated Tests → Push Image → Resolve Environments → Deploy to Idle Environment → Validate Idle Environment → Switch Traffic → Promote Stable Release**.

The live Service is switched only after the idle colour has rolled out healthy and passed the tests through the preview Service. If anything fails before the switch, the live selector is never touched, so users stay on the previous stable colour.

---

## Step 1 – Create the Git repository

```bash
cd food-portal
git init -b main
git add .
git commit -m "Online food ordering portal v1.0.0"
git remote add origin https://github.com/<github-user>/food-portal.git
git push -u origin main
```

## Step 2 – Build the image and test locally

```bash
docker build --build-arg APP_VERSION=v1.0.0 -t <dockerhub-user>/food-portal:v1.0.0 -t <dockerhub-user>/food-portal:latest .
docker run -d --name food-local -p 8080:80 <dockerhub-user>/food-portal:v1.0.0
docker exec -i food-local sh -s http://127.0.0.1 v1.0.0 < tests/smoke-test.sh
```

Open **http://localhost:8080** and check the page, then `docker rm -f food-local`.

## Step 3 – Push the image to Docker Hub

```bash
docker login
docker push <dockerhub-user>/food-portal:v1.0.0
docker push <dockerhub-user>/food-portal:latest
```

## Step 4 – Create the Kubernetes Deployment (3 replicas)

Enable Kubernetes first: Docker Desktop → **Settings → Kubernetes → Enable Kubernetes** (kubeadm) → **Apply & Restart**.

```bash
kubectl config use-context docker-desktop
kubectl apply -f deployment-blue.yaml
kubectl rollout status deployment/food-portal-blue
```

## Step 5 – Configure Jenkins credentials

Jenkins runs on the same machine as Docker Desktop with the **Pipeline**, **Git** and **Credentials Binding** plugins; `docker` and `kubectl` must be on its PATH.

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**

| Kind | ID | Value |
|---|---|---|
| Username with password | `dockerhub-creds` | Docker Hub username + access token |
| Secret file | `kubeconfig` | `C:\Users\<you>\.kube\config` or `~/.kube/config` |

## Step 6 – Create the Jenkins pipeline

**New Item** → `food-portal-pipeline` → **Pipeline** → *Pipeline script from SCM* → Git → repo URL → Branch `*/main` → Script Path `Jenkinsfile` → Save.

## Step 7 – Create the NodePort Services

```bash
kubectl apply -f service.yaml
kubectl apply -f service-preview.yaml
kubectl get services -l app=food-portal
```

Expected: `food-portal 80:30082/TCP` and `food-portal-preview 80:30083/TCP`.

## Step 8 – Deploy through Jenkins

Click **Build Now**. Blue is live, so the pipeline deploys the release to **green**, validates it on the preview Service, then switches the live Service to green.

The first build also registers the `pollSCM` trigger, so later pushes to GitHub start the pipeline automatically.

## Step 9 – Verify the Deployment and all three Pods

```bash
kubectl get deployments -l app=food-portal
kubectl get pods -l app=food-portal -L version
kubectl get service food-portal -o jsonpath="{.spec.selector.version}"
```

Expected: both Deployments `3/3`, 6 pods `Running`, live selector `green`. Open **http://localhost:30082**.

## Step 10 – Add a new feature to the HTML

Add a thank-you section in `index.html`, just before `</main>`:

```html
    <section id="thank-you" class="section">
      <div class="thank-you">
        <h2>Thank you for ordering with Spice Route Kitchen!</h2>
        <p>Your order is being prepared fresh. Track it live from the Orders page, and enjoy 10% off your next meal with code <code>THANKYOU10</code>.</p>
      </div>
    </section>
```

Add to the end of `styles.css`:

```css
.thank-you {
  text-align: center;
  background: linear-gradient(120deg, #dcfce7, #fef9c3);
  border: 1px solid #bbf7d0;
  border-radius: var(--radius);
  padding: 32px 24px;
}
.thank-you h2 { color: var(--green); margin-bottom: 8px; }
.thank-you p { color: var(--muted); max-width: 620px; margin-inline: auto; }
```

Optionally add the check to `tests/smoke-test.sh` so the feature is covered by the automated tests:

```sh
check 'id="thank-you"' "Thank-you message"
```

## Steps 11–13 – New image, push, update Deployment

```bash
git commit -am "Add thank-you message"
git push
```

Jenkins picks up the commit and automatically: builds `food-portal:v1.0.<build>` → runs the tests → pushes it to Docker Hub → deploys it to the idle colour (**blue**) → validates it on the preview Service → switches live traffic to blue.

Manual equivalent (for the record):

```bash
docker build --build-arg APP_VERSION=v1.1.0 -t <dockerhub-user>/food-portal:v1.1.0 .
docker push <dockerhub-user>/food-portal:v1.1.0
kubectl set image deployment/food-portal-blue food-portal=<dockerhub-user>/food-portal:v1.1.0
kubectl rollout status deployment/food-portal-blue
curl http://localhost:30083                                         # validate on preview
kubectl set selector service food-portal app=food-portal,version=blue
```

## Step 14 – Verify the updated application

Open **http://localhost:30082** – the thank-you section is visible and the footer shows the new release.

```bash
kubectl get service food-portal -o jsonpath="{.spec.selector.version}"   # blue
kubectl get pods -l app=food-portal -L version
```

Green still runs the previous release on standby; pointing the live selector back to green is an instant manual rollback.

---

## Faulty release and automated rollback

### 1. Introduce the faulty version

In `nginx.conf`:

```nginx
    location = /healthz {
        access_log off;
        default_type text/plain;
        return 503 "maintenance\n";
    }
```

```bash
git commit -am "Faulty release - health endpoint returns 503"
git push
```

### 2. What the pipeline does

- **Automated Tests** pass (the page content is intact) and the image is pushed.
- **Deploy to Idle Environment** applies the release to the idle colour (green). The new pods fail the readiness probe, so none become Ready and the rollout exceeds its progress deadline.
- The pipeline prints the pod status and warning events, runs `kubectl rollout undo` on the idle Deployment and marks the build **FAILED**.
- **Switch Traffic never runs.** The live Service still selects blue, so users keep getting the stable release with zero downtime.

### 3. Identify the failed rollout

Jenkins console:

```
error: deployment "food-portal-green" exceeded its progress deadline
Release v1.0.N did not become healthy in the green environment. Live traffic remains on blue.
```

Terminal:

```bash
kubectl get pods -l app=food-portal,version=green
kubectl describe pod <green-pod-name>      # Readiness probe failed: HTTP probe failed with statuscode: 503
kubectl get events --field-selector type=Warning --sort-by=.lastTimestamp
kubectl rollout history deployment/food-portal-green
```

### 4. Demonstrate the application is still functional

```bash
kubectl get service food-portal -o jsonpath="{.spec.selector.version}"   # still blue
kubectl rollout status deployment/food-portal-green                       # restored to its previous revision
kubectl get pods -l app=food-portal -L version                           # all 6 pods Running
```

Open **http://localhost:30082** – the stable release (with the thank-you section) is served. **http://localhost:30083** serves the restored green environment.

### 5. Restore the repository

```bash
git revert --no-edit HEAD
git push
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `docker` / `kubectl` not found in Jenkins | Add them to the system PATH and restart Jenkins. |
| Jenkins Windows service cannot reach Docker | `services.msc` → Jenkins → **Log On** → your Windows account → restart. |
| `docker login` credential-store error | Remove `"credsStore"` from the Jenkins user's `~/.docker/config.json`. |
| NodePort not reachable | Use the kubeadm cluster type in Docker Desktop. |
