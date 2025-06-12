#!/usr/bin/env python3
"""
Kubernetes Pod Monitor Operator

This operator watches for pod creation, updates, and deletion events
and sends notifications to Slack.

Requirements:
- kubernetes Python client
- requests for Slack API calls
- asyncio for async operations

Environment Variables:
- SLACK_WEBHOOK_URL: Slack webhook URL for sending messages
- NAMESPACE: Kubernetes namespace to watch (default: default)
"""

import os
import asyncio
import logging
import json
import threading
import time
from datetime import datetime
from typing import Dict, Any, Optional
from http.server import HTTPServer, BaseHTTPRequestHandler

import requests
from kubernetes import client, config, watch
from kubernetes.client.rest import ApiException

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class HealthHandler(BaseHTTPRequestHandler):
    """HTTP handler for health checks"""
    
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                'status': 'healthy',
                'timestamp': datetime.utcnow().isoformat()
            }
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # Suppress default HTTP logging
        pass


class HealthServer:
    """HTTP server for health checks"""
    
    def __init__(self, port=8080):
        self.port = port
        self.server = None
        self.thread = None
        
    def start(self):
        """Start the health server in a separate thread"""
        self.server = HTTPServer(('', self.port), HealthHandler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()
        logger.info(f"Health server started on port {self.port}")
        
    def stop(self):
        """Stop the health server"""
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        if self.thread:
            self.thread.join()
        logger.info("Health server stopped")


class SlackNotifier:
    """Handles Slack notifications"""
    
    def __init__(self, webhook_url: str):
        self.webhook_url = webhook_url
        
    def send_message(self, message: str) -> bool:
        """Send message to Slack"""
        try:
            payload = {
                "text": message,
                "username": "k8s-pod-monitor",
                "icon_emoji": ":robot_face:"
            }
            
            response = requests.post(
                self.webhook_url,
                json=payload,
                timeout=10
            )
            
            if response.status_code == 200:
                logger.info(f"Slack message sent successfully: {message}")
                return True
            else:
                logger.error(f"Failed to send Slack message. Status: {response.status_code}")
                return False
                
        except Exception as e:
            logger.error(f"Error sending Slack message: {e}")
            return False


class PodMonitorOperator:
    """Main operator class that monitors pod events"""
    
    def __init__(self, namespace: str = "default"):
        self.namespace = namespace
        self.slack_notifier = None
        self.v1 = None
        self.health_server = None
        self.running = False
        
        # Initialize health server
        self.health_server = HealthServer()
        
        # Initialize Slack notifier
        webhook_url = os.getenv('SLACK_WEBHOOK_URL')
        if not webhook_url:
            raise ValueError("SLACK_WEBHOOK_URL environment variable is required")
            
        self.slack_notifier = SlackNotifier(webhook_url)
        
        # Initialize Kubernetes client
        self._init_kubernetes_client()
        
    def _init_kubernetes_client(self):
        """Initialize Kubernetes client"""
        try:
            # Try to load in-cluster config first
            config.load_incluster_config()
            logger.info("Loaded in-cluster Kubernetes config")
        except Exception:
            try:
                # Fall back to local kubeconfig
                config.load_kube_config()
                logger.info("Loaded local Kubernetes config")
            except Exception as e:
                logger.error(f"Failed to load Kubernetes config: {e}")
                raise
                
        self.v1 = client.CoreV1Api()
        
    def _extract_pod_name(self, pod: Dict[str, Any]) -> str:
        """Extract pod name from pod object"""
        return pod.get('metadata', {}).get('name', 'unknown')
        
    def _handle_pod_event(self, event_type: str, pod: Dict[str, Any]):
        """Handle different pod events"""
        pod_name = self._extract_pod_name(pod)
        
        if event_type == 'ADDED':
            message = f"Hello world from {pod_name}"
            self.slack_notifier.send_message(message)
            
        elif event_type == 'MODIFIED':
            message = f"Things have changed, {pod_name}"
            self.slack_notifier.send_message(message)
            
        elif event_type == 'DELETED':
            message = f"Goodbye world from, {pod_name}"
            self.slack_notifier.send_message(message)
            
        logger.info(f"Processed {event_type} event for pod: {pod_name}")
        
    def run(self):
        """Main run loop"""
        logger.info(f"Starting Pod Monitor Operator for namespace: {self.namespace}")
        
        # Start health server
        self.health_server.start()
        self.running = True
        
        w = watch.Watch()
        
        try:
            while self.running:
                try:
                    logger.info("Starting to watch pod events...")
                    
                    for event in w.stream(
                        self.v1.list_namespaced_pod,
                        namespace=self.namespace,
                        timeout_seconds=60  # Add timeout to allow graceful shutdown
                    ):
                        if not self.running:
                            break
                            
                        event_type = event['type']
                        pod = event['object']
                        
                        # Skip events for pods that are not user-created
                        # (avoid noise from system pods)
                        if self._should_ignore_pod(pod):
                            continue
                            
                        self._handle_pod_event(event_type, pod.to_dict())
                        
                except ApiException as e:
                    logger.error(f"Kubernetes API error: {e}")
                    # Wait before retrying
                    if self.running:
                        time.sleep(5)
                    
                except Exception as e:
                    logger.error(f"Unexpected error: {e}")
                    # Wait before retrying
                    if self.running:
                        time.sleep(5)
                        
        finally:
            self.stop()
            
    def stop(self):
        """Stop the operator gracefully"""
        logger.info("Stopping Pod Monitor Operator...")
        self.running = False
        if self.health_server:
            self.health_server.stop()
                
    def _should_ignore_pod(self, pod) -> bool:
        """Check if pod should be ignored (system pods, etc.)"""
        # Skip pods in kube-system namespace
        if pod.metadata.namespace == 'kube-system':
            return True
            
        # Skip pods with system labels
        labels = pod.metadata.labels or {}
        if any(label.startswith('k8s-app') for label in labels.keys()):
            return True
            
        return False


def main():
    """Main entry point"""
    try:
        namespace = os.getenv('NAMESPACE', 'default')
        operator = PodMonitorOperator(namespace)
        operator.run()
        
    except KeyboardInterrupt:
        logger.info("Received interrupt signal, shutting down...")
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        raise


if __name__ == "__main__":
    main()
