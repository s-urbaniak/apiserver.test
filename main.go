package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(
			w, `# metrics
tube_current_jobs_ready{exported_instance="queue01:11300",instance="10.4.1.100:8080",job="beanstalkd",k8s_namespace="dev",k8s_pod_name="dumb-metrics-68bb8f6dd6-5m6sv",k8s_service="beanstalkd",tube="rql"}	50000
tube_current_jobs_ready{exported_instance="queue01:11300",instance="10.4.1.100:8080",job="beanstalkd",k8s_namespace="dev",k8s_pod_name="dumb-metrics-68bb8f6dd6-5m6sv",k8s_service="beanstalkd",tube="trigger"}	10000
`,
		)
	})

	http.ListenAndServe(":8888", nil)
}
