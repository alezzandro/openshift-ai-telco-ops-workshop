# CPU workbench — start here

This Jupyter workbench is **CPU only**. It lives in the Data Science Project
`telco-ops-notebooks`, which has **no Kueue LocalQueue**.

Serving projects (`telco-ops-demo`, `telco-ran-ai`, `telco-core-ai`) use Kueue.
The OpenShift AI dashboard then shows only hardware profiles that name a local
queue, so a **CPU only** workbench cannot be created there. This project exists
so you can still show Jupyter without taking an L4 away from model serving.

## Red Hat example notebooks

Setup cloned [rh-aiservices-bu/llm-on-openshift](https://github.com/rh-aiservices-bu/llm-on-openshift)
into `llm-on-openshift/`.

Open this notebook for the customer-facing LangChain + vLLM walkthrough:

`llm-on-openshift/examples/notebooks/langchain/Langchain-vLLM-Prompt-memory.ipynb`

Upstream copy:
https://github.com/rh-aiservices-bu/llm-on-openshift/blob/main/examples/notebooks/langchain/Langchain-vLLM-Prompt-memory.ipynb

## Point it at this cluster

After **C3** (register Ministral 3 14B in Model Registry **workshop**, then deploy that version) a predictor Service exists in `telco-ops-demo`.
In the first notebook cell set:

```python
inference_server_url = "http://ministral-3-14b-instruct-version-predictor.telco-ops-demo.svc.cluster.local:8080"
```

KServe Standard predictor Services are headless: DNS is the pod IP, so use
container port **8080**, not Service port 80. Use the in-cluster Service, not
the Route. Then `/v1` is appended by the LangChain `VLLMOpenAI` client
(`openai_api_base=f"{inference_server_url}/v1"`).

Find the Service name:

```bash
oc get svc -n telco-ops-demo
```

or **OpenShift AI → telco-ops-demo → Models** and copy the internal endpoint.

`model_name` in that notebook is an example (`mistralai/Mistral-7B-Instruct-v0.2`).
Change it to the model id your vLLM server reports (`/v1/models`) — on this
lab that is `ministral-3-14b-instruct-version`.

## Docs

- https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_in_your_data_science_ide/working_in_jupyterlab
- https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_openshift_ai/managing-workloads-with-kueue
