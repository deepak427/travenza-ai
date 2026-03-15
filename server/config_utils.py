import os
import logging
import google.auth

logger = logging.getLogger(__name__)

def get_project_id():
    env_project_id = os.getenv("PROJECT_ID")
    if env_project_id and env_project_id != "your-project-id":
        return env_project_id
    try:
        _, auth_project_id = google.auth.default()
        if auth_project_id:
            logger.info(f"Fetched PROJECT_ID from Google Auth: {auth_project_id}")
            return auth_project_id
    except Exception as e:
        logger.warning(f"Could not determine PROJECT_ID from Google Auth: {e}")
    return "your-project-id"
