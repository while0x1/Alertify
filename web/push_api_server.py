from fastapi import FastAPI, HTTPException, Header, status, Request
from pydantic import BaseModel
import firebase_admin
from firebase_admin import credentials, messaging, firestore, auth # Import 'auth' for Firebase Auth
from typing import Optional
import os
from dotenv import load_dotenv
import uvicorn
import time
import datetime
import uuid
from fastapi.responses import FileResponse, PlainTextResponse
from fastapi import Response
from google.cloud.firestore_v1.base_query import FieldFilter

import logging
from logging.handlers import RotatingFileHandler
import json

from cachetools import TTLCache
# Create a cache that holds 10,000 projects, items expire after 12 hours (43200 seconds)
auth_cache = TTLCache(maxsize=10000, ttl=43200)

#CONSTANTS------------------
PRO_SUB_LIMIT = 5000




# Create a formatter for clean, readable logs

# 1. Console Handler (See it in your terminal)
LOG_FILE = '/home/ubuntu/alertify/alertify.log'

# 1. Setup your File Handler
file_handler = RotatingFileHandler(LOG_FILE, maxBytes=5000000, backupCount=5)
formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
file_handler.setFormatter(formatter)

# 2. Get the "brains" of the loggers
logger = logging.getLogger("Alertify")
g_error = logging.getLogger("gunicorn.error")
# Catch the Uvicorn layer too

# 3. Force them to use your file handler and ignore their default behavior
for l in [logger, g_error]:
    l.handlers = [file_handler]
    l.setLevel(logging.INFO)
    l.propagate = False

load_dotenv()
print('Loading api FCM server')
print(str(uuid.uuid4()))



from fastapi.responses import JSONResponse

# This catches ANY error that escapes your endpoints



firebase_credentials_path = os.getenv("FIREBASE_CREDENTIALS_PATH")
if not firebase_credentials_path:
    raise RuntimeError("FIREBASE_CREDENTIALS_PATH environment variable not set.")

try:
    cred = credentials.Certificate(firebase_credentials_path)
    firebase_admin.initialize_app(cred)
    db = firestore.client()
except Exception as e:
    raise RuntimeError(f"Failed to initialize Firebase Admin SDK: {e}. "
                       "Please ensure FIREBASE_CREDENTIALS_PATH points to a valid JSON file.")

app = FastAPI(title="Alertify Alert Server")


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    # Now your custom logger catches the system-level crashes
    logger.error(f"CRITICAL UNHANDLED ERROR on {request.url}: {exc}")
    
    return JSONResponse(
        status_code=500,
        content={"message": "Internal Server Error"},
    )


class AlertRequest(BaseModel):
    projectId: str
    title: str
    message: str

class CreateProjectRequest(BaseModel):
    projectName: str



VALID_API_KEYS = {"org-secret-key-123", "org-secret-key-456"}

# Default values for user profiles stored in the 'users' collection
DEFAULT_USER_REQUEST_LIMIT = 10
THIRTY_DAYS_IN_SECONDS = 30 * 24 * 60 * 60

# Max number of projects a user (identified by userId UUID) can create
MAX_PROJECTS_PER_USER = 1 
logger.info('APP-LOG- Initializing Appliction')

'''
@app.post("/internal/mqtt-ingest")
async def handle_mqtt(request: Request):
    try:
        logger.info(f'ingest endpoint triggered')
        # 1. Grab the Topic from the custom Header
        topic = request.headers.get("X-MQTT-Topic", "")
        topic_parts = topic.split("/")
        project_id = topic_parts[2] if len(topic_parts) >= 3 else None
        logger.info(f'ingest endpoint triggered with proj_id {project_id}')
        if not project_id:
            return {"status": "error", "message": "No Project ID"}, 400

    # 2. Get the Project Doc to find the Owner (User ID)
        proj_doc = db.collection('projects').document(project_id).get()
        if not proj_doc.exists:
            return {"status": "error", "message": "Project not found"}, 404
    
        user_id = proj_doc.to_dict().get('createdByInstallId')

        logger.info(f'ingest triggered by {user_id}')

        if not user_id:
            return {"status": "error", "message": "Unauthenticated"}, 401
        
        # 3. GO STRAIGHT TO THE USER (Saves one Firestore read)
        user_ref = db.collection('users').document(user_id)
        user_doc = user_ref.get()

        if user_doc.exists:
            user_data = user_doc.to_dict()
        else:
            return {"status": "error", "message": "Unauthenticated"}, 401

        # 2. Grab the raw bytes from the Body and decode to string
        raw_bytes = await request.body()
        payload_str = raw_bytes.decode("utf-8")


        # 4. The TRUE Universal Logic
        try:
            # If it's an ESP32 sending JSON, this succeeds
            parsed_json = json.loads(payload_str)
            alert_msg = parsed_json.get("message", str(parsed_json))
        except (json.JSONDecodeError, TypeError):
            # If it's a PLC sending a raw string, it falls back here safely!
            alert_msg = payload_str

        logger.info(f"🚀 ALERT TRIGGERED:")
        logger.info(f" -> Project ID: {project_id}")
        logger.info(f" -> Message: {alert_msg}")

        return {"status": "success"}

    except Exception as e:
        logger.error(f"Failed to process MQTT request: {e}")
        return {"status": "error", "detail": str(e)}, 500
'''

@app.post("/internal/mqtt-ingest")
async def handle_mqtt_ingest(request: Request):
    try:
        # 1. Identify Source from Headers
        topic_header = request.headers.get("X-MQTT-Topic", "")
        # Expected topic format: alertify/project/{projectId}
        topic_parts = topic_header.split("/")
        project_id = topic_parts[2] if len(topic_parts) >= 3 else None

        if not project_id:
            logger.warning("MQTT-INGEST: Missing project ID in topic")
            return {"status": "error", "message": "Invalid topic structure"}, 400

        # 2. Extract and Parse Payload
        raw_bytes = await request.body()
        payload_str = raw_bytes.decode("utf-8")
        
        try:
            # Try parsing as JSON first (ESP32/Modern sensors)
            parsed_json = json.loads(payload_str)
            alert_message = parsed_json.get("message", str(parsed_json))
            alert_title = parsed_json.get("title", f"Alert: {project_id}")
        except (json.JSONDecodeError, TypeError):
            # Fallback to raw string (Legacy PLCs)
            alert_message = payload_str
            alert_title = f"System Alert: {project_id}"

        # 3. Security & Ownership Check (Crucial)
        project_doc_ref = db.collection('projects').document(project_id)
        project_snapshot = project_doc_ref.get()

        if not project_snapshot.exists:
            logger.error(f"MQTT-INGEST: Project {project_id} not found")
            return {"status": "error", "message": "Project not found"}, 404
        
        project_data = project_snapshot.to_dict()
        user_id = project_data.get('createdByInstallId')
        
        if not project_data.get('enabled', False):
            logger.warning(f"MQTT-INGEST: Project {project_id} is disabled")
            return {"status": "error", "message": "Project disabled"}, 403

        # 4. Master Transaction (Quota & Burst Check)
        user_profile_ref = db.collection('users').document(user_id)
        current_unix_time = int(time.time())

        try:
            # Reusing your core transaction logic
            result = process_alert_request(db.transaction(), user_profile_ref, current_unix_time)
            
            if not result["allowed"]:
                if result["reason"] == "quota_exceeded" and result.get("trigger_warning_fcm"):
                    await send_direct_fcm_notification(
                        result["fcm_token"], 
                        "Alert Limit Exceeded", 
                        "You have reached your monthly alert limit. Please upgrade to Pro."
                    )
                logger.warning(f"MQTT-INGEST: Request blocked for {user_id} - {result['reason']}")
                return {"status": "blocked", "reason": result["reason"]}, 429

        except Exception as e:
            logger.error(f"Transaction Error in MQTT flow: {e}")
            return {"status": "error", "message": "Transaction failed"}, 500

        # 5. Fire the FCM Message
        current_timestamp_ms = int(time.time() * 1000)
        fcm_topic = f"project_{project_id}"
        mId = str(uuid.uuid4())

        message = messaging.Message(
            notification=messaging.Notification(title=alert_title, body=alert_message),
            data={
                "title": alert_title,
                "message": alert_message,
                "messageId": mId,
                "timestamp": str(current_timestamp_ms),
                "projectId": project_id,
                "sender_identifier": user_id
            },
            topic=fcm_topic,
            android=messaging.AndroidConfig(priority="high"),
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(aps=messaging.Aps(content_available=True))
            ),
        )

        fcm_response = messaging.send(message)
        logger.info(f"🚀 MQTT ALERT SENT: User [{user_id}] | Project [{project_id}] | Msg: {alert_message}")

        return {
            "status": "success",
            "fcm_id": fcm_response,
            "internal_id": mId
        }

    except Exception as e:
        logger.error(f"Failed to process MQTT request: {e}")
        return {"status": "error", "detail": str(e)}, 500

#TODO =====================================
#MUST delete cache data for any stripe webhooks 

@app.post("/internal/mqtt-auth")
async def handle_mqtt_auth(request: Request):
    data = await request.json()
    project_uuid = data.get("username") # The 8-char project ID
    user_id_attempt = data.get("password") # The user_id acting as secret

    if project_uuid in auth_cache:
        logger.info('Cached Project! Skip FS Read and Returning Cache Data')
        return auth_cache[project_uuid] # Instant return, zero cost
    # ONE READ: Get the project doc directly
    project_ref = db.collection('projects').document(project_uuid)
    project_doc = project_ref.get()

    if project_doc.exists:
        project_data = project_doc.to_dict()
        # Check if the secret (password) matches the creator's ID
        if project_data.get('createdByInstallId') == user_id_attempt:
            
        # 4. Master Transaction (Quota & Burst Check)
            user_profile_ref = db.collection('users').document(user_id_attempt)
            user_doc = user_profile_ref.get()
            if user_doc.exists:
                user_data = user_doc.to_dict()
                is_pro = user_data.get('isPro',"")
                tier = "pro" if is_pro else "free"
                rate_limit = "100" if is_pro else "0.0011"
                response_data = {
                    "result": "allow",
                    "user_properties": {
                        "user_id": user_id_attempt,
                        "tier": "pro" if is_pro else "free",
                        "quota_limit": "100" if is_pro else "0.0011"
                    }
                }
                auth_cache[project_uuid] = response_data

                logger.info(f"✅ Auth Success: {project_uuid}, tier: {tier}") 
                return {"result": "allow","user_properties":{"tier":tier,"quota_limit":rate_limit}}
        
    logger.warning(f"❌ Auth Failed for project: {project_uuid} quota_limit {rate_limit}")
    return {"result": "deny"}


# Add this to your FastAPI main.py
@app.post("/delete-user-data")
async def delete_user_data(
    x_user_id: str = Header(None, alias="X-User-Id")
):
    if not x_user_id:
        raise HTTPException(status_code=400, detail="Missing User ID")

    # 1. Logic to delete the user's projects/links from Firestore
    # 2. Logic to wipe their FCM token from your registration table
    
    # Success response
    return {"status": "success", "message": "User data successfully deleted."}


@app.get("/favicon.ico", include_in_schema=False)
async def favicon():
    # We use the exact same SVG path from your logo
    # The 'fill' is set to your primary brand color (#38bdf8)
    svg_icon = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#38bdf8" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path>
        <line x1="12" y1="7" x2="12" y2="11"></line>
        <line x1="12" y1="14" x2="12.01" y2="14"></line>
    </svg>
    """
    return Response(content=svg_icon, media_type="image/svg+xml")

@app.get("/terms", response_class=FileResponse, tags=["Web"])
async def serve_landing_page():
    """
    Serves the static index.html landing page for Alertify.
    """
    html_file_path = os.path.join(os.path.dirname(__file__), "terms.html")
    
    if os.path.exists(html_file_path):
        return FileResponse(html_file_path)
    else:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, 
            detail="Landing page not found. Please ensure index.html is in the same directory."
        )

@app.get("/robots.txt", include_in_schema=False)
async def get_robots():
    robots_content = """User-agent: *
Allow: /
Disallow: /*.apk$
Disallow: /*.aab$
"""
    return PlainTextResponse(content=robots_content)

@app.get("/sitemap.xml", include_in_schema=False)
async def get_sitemap():
    sitemap_content = """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://alertify.while0x1.com/</loc>
    <changefreq>weekly</changefreq>
    <priority>1.0</priority>
  </url>
</urlset>
"""
    return Response(content=sitemap_content, media_type="application/xml")

# --- ENDPOINT: Serve Landing Page ---
@app.get("/", response_class=FileResponse, tags=["Web"])
async def serve_landing_page():
    """
    Serves the static index.html landing page for Alertify.
    """
    html_file_path = os.path.join(os.path.dirname(__file__), "index.html")
    
    if os.path.exists(html_file_path):
        return FileResponse(html_file_path)
    else:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, 
            detail="Landing page not found. Please ensure index.html is in the same directory."
        )

@app.get("/user-stats")
async def get_user_stats(
    x_user_id: Optional[str] = Header(None)
):
    if not x_user_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="X-User-Id header is required.")

    user_profile_ref = db.collection('users').document(x_user_id)
    snapshot = user_profile_ref.get()

    if not snapshot.exists:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User profile not found. Send an alert to generate one.")

    data = snapshot.to_dict()
    current_unix_time = int(time.time())
    
    # Get the current month string (e.g., "2026-05")
    current_month_str = datetime.datetime.fromtimestamp(current_unix_time).strftime('%Y-%m')
    
    # THE FIX: Only display the request counter if it actually belongs to this month
    last_recorded_month = data.get('lastRequestMonth', '')
    if last_recorded_month == current_month_str:
        requests_this_month = data.get('requestCounter', 0)
    else:
        requests_this_month = 0 # It's a new month, their effective usage is 0
    
    # Calculate if they are currently on Pro
    is_valid_sub = data.get('validSubscription', False)
    sub_end_time = data.get('subscriptionEnd', 0)
    is_pro_active = is_valid_sub and current_unix_time < sub_end_time
    
    # Determine their current monthly limit
    limit = PRO_SUB_LIMIT if is_pro_active else DEFAULT_USER_REQUEST_LIMIT

    return {
        "tier": "Pro" if is_pro_active else "Hacker",
        "requestsThisMonth": requests_this_month,
        "monthlyLimit": limit,
        "totalAllTimeRequests": data.get('totalRequests', 0),
        "projectsCreated": data.get('projectsCreatedCount', 0),
        "subscriptionActive": is_pro_active
    }

# --- Helper function to send direct FCM notification ---
async def send_direct_fcm_notification(fcm_token: str, title: str, body: str):
    try:
        message = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            token=fcm_token, # Target specific device token
            android=messaging.AndroidConfig(priority="high"),
            apns=messaging.APNSConfig(payload=messaging.APNSPayload(aps=messaging.Aps(content_available=True))),
        )
        response = messaging.send(message)
        print(f"Direct FCM message sent to token (first 10 chars): {fcm_token[:10]}... ID: {response}")
        return True
    except messaging.UnregisteredError:
        print(f"Failed to send direct FCM: Token {fcm_token[:10]}... is unregistered (stale).")
        # In a real app, you'd also want to clear this token from the user's profile in Firestore
        return False
    except Exception as e:
        print(f"Error sending direct FCM to {fcm_token[:10]}...: {e}")
        return False

# --- ENDPOINT: Check User Subscription ---
@app.post("/check-user-subscription")
async def check_user_subscription(
    x_user_id: Optional[str] = Header(None) # Expecting the userId UUID from Flutter
):
    if not x_user_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="X-User-Id header is required.")

    user_profile_ref = db.collection('users').document(x_user_id)
    doc_snapshot = user_profile_ref.get() 

    current_unix_time = int(time.time())

    has_valid_subscription = False
    message = "Subscription check failed."

    if doc_snapshot.exists:
        user_data = doc_snapshot.to_dict()
        is_valid_flag = user_data.get('validSubscription', False)
        subscription_end_time = user_data.get('subscriptionEnd', 0)

        if is_valid_flag and subscription_end_time > current_unix_time:
            has_valid_subscription = True
            message = "User has a valid subscription."
        elif not is_valid_flag:
            message = "Your subscription is not active. Please subscribe."
        elif subscription_end_time <= current_unix_time:
            message = "Your subscription has expired. Please renew."
        else:
            message = "Unable to determine subscription status."
    else:
        message = "No subscription found for this user ID. Please ensure your app is registered or subscribe."

    return {"has_valid_subscription": has_valid_subscription, "message": message}

@app.post("/update-fcm-token")
async def update_fcm_token(
    x_user_id: Optional[str] = Header(None), # The unique app installation ID
    x_fcm_token: Optional[str] = Header(None) # The new FCM token
):
    print('update-fcm-token endpoint request received')
    if not x_user_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="X-User-Id header is required.")
    if not x_fcm_token:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="X-FCM-Token header is required.")

    user_profile_ref = db.collection('users').document(x_user_id)

    @firestore.transactional
    def update_token_in_profile(transaction, user_profile_ref_in_tx):
        snapshot = user_profile_ref_in_tx.get(transaction=transaction)
        user_data = snapshot.to_dict() if snapshot.exists else {}

        # Update the fcmToken field
        user_data['fcmToken'] = x_fcm_token
        user_data['fcmTokenLastUpdated'] = int(time.time()) # Optional: track when it was last updated

        # If the user profile didn't exist, this request creates a minimal one.
        # This is important for cases where a direct FCM token update might be the *first* interaction.
        current_unix_time = int(time.time())
        if not snapshot.exists:
            # Inside your user initialization route
            logger.info(f"APP-LOG-🆕 NEW USER CREATED: ID [{x_user_id}] - Initialized with Free Tier limits.")
            user_data.setdefault('joinTime', current_unix_time)
            user_data.setdefault('lastRequestTime', current_unix_time)
            user_data.setdefault('requestCounter', 0)
            user_data.setdefault('requestLimit', DEFAULT_USER_REQUEST_LIMIT)
            user_data.setdefault('subscriptionEnd', current_unix_time) # Default to expired
            user_data.setdefault('totalRequests', 0)
            user_data.setdefault('validSubscription', False)
            user_data.setdefault('projectsCreatedCount', 0)
            user_data.setdefault('limitNotificationSent', False)
            user_data.setdefault('projectLimit', 1)
            user_data.setdefault('createdAt', firestore.SERVER_TIMESTAMP)
            # NEW: Initialize the flag
            # api_key is not known here, so 'firstApiKeyUsed' will be missing until send-alert is called

        transaction.set(user_profile_ref_in_tx, user_data)
        
        return user_data

    try:
        updated_profile = update_token_in_profile(db.transaction(), user_profile_ref)
        print(f"FCM token for user '{x_user_id}' updated successfully. New token (first 10 chars): {x_fcm_token[:10]}...")
        return {"message": "FCM token updated successfully", "user_id": x_user_id}
    except Exception as e:
        print(f"Error updating FCM token for user '{x_user_id}': {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to update FCM token: {str(e)}")

# --- MODIFIED ENDPOINT: create-alertify-project ---
@app.post("/create-alertify-project")
async def create_alertify_project(
    request: CreateProjectRequest,
    x_user_id: Optional[str] = Header(None), # Expecting the userId UUID from Flutter
    x_firebase_auth_token: Optional[str] = Header(None) # Optional: Firebase Auth for logging creator_uid
):
    if not x_user_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="X-User-Id header is required for project creation.")

    creator_uid = None
    if x_firebase_auth_token:
        try:
            decoded_token = auth.verify_id_token(x_firebase_auth_token)
            creator_uid = decoded_token['uid']
        except Exception as e:
            print(f"Warning: Invalid Firebase Auth Token for project creation: {e}")

    # NEW LOGIC: Check and increment user's project creation count
    user_profile_ref = db.collection('users').document(x_user_id)

    @firestore.transactional
    def check_and_increment_project_count(transaction, user_profile_ref_in_tx):
        snapshot = user_profile_ref_in_tx.get(transaction=transaction)
        
        user_data = snapshot.to_dict() if snapshot.exists else {}
        projects_created_count = user_data.get('projectsCreatedCount', 0)
        project_limit = user_data.get('projectLimit', MAX_PROJECTS_PER_USER)

        if projects_created_count >= project_limit :
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"You have reached the maximum limit of {project_limit} projects for this user."
            )
        
        # Increment the count
        user_data['projectsCreatedCount'] = projects_created_count + 1
        
        current_unix_time = int(time.time())
        if not snapshot.exists: 
             user_data.setdefault('joinTime', current_unix_time)
             user_data.setdefault('lastRequestTime', current_unix_time)
             user_data.setdefault('requestCounter', 0)
             user_data.setdefault('requestLimit', DEFAULT_USER_REQUEST_LIMIT)
             user_data.setdefault('subscriptionEnd', current_unix_time)
             user_data.setdefault('totalRequests', 0)
             user_data.setdefault('validSubscription', False)
             user_data.setdefault('projectsCreatedCount', 1)
             user_data.setdefault('projectLimit', 1)
             user_data.setdefault('limitNotificationSent', False)
             user_data.setdefault('createdAt', firestore.SERVER_TIMESTAMP)# NEW: Initialize the flag

        transaction.set(user_profile_ref_in_tx, user_data)
        return user_data

    try:
        updated_user_profile_data = check_and_increment_project_count(db.transaction(), user_profile_ref)
        print(f"User {x_user_id} now has {updated_user_profile_data['projectsCreatedCount']} projects.")
        # Assuming 'project_name' is the string they typed and 'project_id' is your generated ID
    except HTTPException as e:
        raise e
    except Exception as e:
        print(f"Error checking/incrementing project count for {x_user_id}: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to manage user project count: {str(e)}")


    new_project_id = str(uuid.uuid4()).replace("-", "")[:8]

    project_doc_ref = db.collection('projects').document(new_project_id)
    try:
        project_doc_ref.set({ 
            'displayName': request.projectName,
            'ownerUid': creator_uid,
            'createdByInstallId': x_user_id,
            'enabled': True,
            'createdAt': firestore.SERVER_TIMESTAMP,
            'rateLimitConfig': {'limit': 20, 'window_seconds': 60} # Project's *default* config, not actively limited here
        })
        logger.info(f"APP-LOG-📁 PROJECT CREATED: Name [{request.projectName}] | ID [{new_project_id}] | By [{x_user_id}]")
        return {"message": "Project created successfully", "projectId": new_project_id, "projectName": request.projectName}
    except Exception as e:
        print(f"Error creating project: {e}")
        logger.error(f"APP-LOG-❌ FAILED TO CREATE PROJECT: User [{x_user_id}] | Error: {str(e)}", exc_info=True)
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to create project: {str(e)}")

BURST_CAPACITY = 30
REFILL_RATE = 0.5

@firestore.transactional
def process_alert_request(transaction, user_ref, current_unix_time):
    # 1. THE SINGLE READ
    snapshot = user_ref.get(transaction=transaction)
    current_month_str = datetime.datetime.fromtimestamp(current_unix_time).strftime('%Y-%m')

    # 2. SCHEMA INITIALIZATION
    user_data = snapshot.to_dict() if snapshot.exists else {
        'joinTime': current_unix_time,
        'requestCounter': 0,
        'totalRequests': 0,
        'requestLimit': DEFAULT_USER_REQUEST_LIMIT, 
        'validSubscription': False,
        'subscriptionEnd': current_unix_time, 
        'projectsCreatedCount': 0,
        'limitNotificationSent': False,
        'lastRequestMonth': current_month_str,
        'availableTokens': BURST_CAPACITY,
        'lastRateLimitCheck': current_unix_time
    }

    # 3. MONTHLY RESET LOGIC
    if user_data.get('lastRequestMonth') != current_month_str:
        user_data['requestCounter'] = 0
        user_data['lastRequestMonth'] = current_month_str
        user_data['limitNotificationSent'] = False

    # 4. DETERMINE CURRENT MONTHLY LIMIT
    is_valid_sub = user_data.get('validSubscription', False)
    sub_end_time = user_data.get('subscriptionEnd', 0)
    current_request_limit = PRO_SUB_LIMIT if (is_valid_sub and current_unix_time < sub_end_time) else user_data.get('requestLimit', DEFAULT_USER_REQUEST_LIMIT)

    # 5. HARD QUOTA CHECK
    if user_data['requestCounter'] >= current_request_limit:
        # Check if we need to send the warning FCM
        had_notification_sent = user_data.get('limitNotificationSent', False)
        trigger_warning = not had_notification_sent
        
        if trigger_warning:
            user_data['limitNotificationSent'] = True
            transaction.set(user_ref, user_data) # Save the fact that we warned them
            
        return {
            "allowed": False, 
            "reason": "quota_exceeded", 
            "trigger_warning_fcm": trigger_warning,
            "fcm_token": user_data.get('fcmToken')
        }

    # 6. BURST LIMIT CHECK (Token Bucket)
    last_check = user_data.get('lastRateLimitCheck', current_unix_time)
    current_tokens = user_data.get('availableTokens', BURST_CAPACITY)
    time_passed = current_unix_time - last_check
    new_tokens = min(BURST_CAPACITY, current_tokens + (time_passed * REFILL_RATE))

    if new_tokens < 1:
        return {"allowed": False, "reason": "burst_limit"}

    # 7. APPROVED: UPDATE COUNTERS
    user_data['availableTokens'] = new_tokens - 1
    user_data['lastRateLimitCheck'] = current_unix_time
    user_data['lastRequestTime'] = current_unix_time
    user_data['requestCounter'] += 1
    user_data['totalRequests'] += 1

    # 8. THE SINGLE WRITE
    transaction.set(user_ref, user_data)

    return {"allowed": True}

# --- MODIFIED ENDPOINT: send-alert ---
@app.post("/send-alert")
async def send_alert(
    request: AlertRequest,
    x_user_id: Optional[str] = Header(None),
):
    if not x_user_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="X-User-Id header is required.")

    # --- 1. Project Security Check (Unchanged & Excellent) ---
    if not request.projectId or len(request.projectId) < 8:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid projectId.")

    project_doc_ref = db.collection('projects').document(request.projectId)
    project_snapshot = project_doc_ref.get()

    if not project_snapshot.exists:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Project not found.")
    
    project_data = project_snapshot.to_dict()
    
    if project_data.get('createdByInstallId') != x_user_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Unauthorized.")
    if not project_data.get('enabled', False):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Project disabled.")

    # --- 2. The Single Master Transaction ---
    user_profile_ref = db.collection('users').document(x_user_id)
    current_unix_time = int(time.time())
    # Inside your message sending logic

    try:
        # One transaction to rule them all
        result = process_alert_request(db.transaction(), user_profile_ref, current_unix_time)
        
        if not result["allowed"]:
            if result["reason"] == "burst_limit":
                raise HTTPException(status_code=429, detail="Burst capacity reached.", headers={"Retry-After": "2"})
            elif result["reason"] == "quota_exceeded":
                # Handle the one-time warning push notification
                if result.get("trigger_warning_fcm") and result.get("fcm_token"):
                     # AWAIT your async fcm function here
                     await send_direct_fcm_notification(
                         result["fcm_token"], 
                         "Alert Limit Exceeded", 
                         "You have reached your monthly alert limit. Please upgrade to Pro."
                     )
                raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail="Monthly limit reached.")

    except HTTPException as e:
        raise e 
    except Exception as e:
        print(f"Transaction Error: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

    # --- 3. Send the FCM Message (Unchanged) ---
    current_timestamp_ms = int(time.time() * 1000)
    topic = f"project_{request.projectId}"
    mId = str(uuid.uuid4())
    
    message = messaging.Message(
        notification=messaging.Notification(title=request.title, body=request.message),
        data={
            "title": request.title,
            "message": request.message,
            "messageId": mId,
            "timestamp": str(current_timestamp_ms),
            "projectId": request.projectId,
            "sender_identifier": x_user_id
        },
        topic=topic,
        android=messaging.AndroidConfig(priority="high"),
        apns=messaging.APNSConfig(payload=messaging.APNSPayload(aps=messaging.Aps(content_available=True))),
    )
    
    try:
        response = messaging.send(message)
        logger.info(f"APP-LOG-✅ MESSAGE SENT: User [{x_user_id}] | Project [{request.projectId}] ")
        return {
            "message": "Alert sent successfully",
            "fcm_message_id": response,
            "message_id": mId,  
            "server_timestamp_ms": current_timestamp_ms
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to send alert: {str(e)}")


# --- ENDPOINT: Serve APK Download ---
@app.get("/alertify.apk", tags=["Web"])
async def download_apk():
    """
    Serves the Android APK file for download.
    """
    # Point to the actual file on your server
    apk_file_path = os.path.join(os.path.dirname(__file__), "app-release.apk")
    
    if os.path.exists(apk_file_path):
        return FileResponse(
            path=apk_file_path, 
            # This media_type tells the phone exactly what kind of file it is
            media_type="application/vnd.android.package-archive",
            # This renames the file from 'app-release.apk' to 'alertify.apk' upon download
            filename="alertify.apk" 
        )
    else:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, 
            detail="APK file not found. Please ensure app-release.apk is in the same directory."
        )



import stripe
import time

#create payment link
#create webhook

# 1. Set your keys (Get these from your Stripe Dashboard)
stripe.api_key = "sk_test_"
ENDPOINT_SECRET = "whsec_"

@app.post("/stripe-webhook")
async def stripe_webhook(request: Request, stripe_signature: str = Header(None, alias="stripe-signature")):
    # In your Webhook, right before processing the upgrade
    logger.info("APP-LOG-🔔 Webhook received!")

    if not stripe_signature:
        raise HTTPException(status_code=400, detail="Missing Stripe signature")

    # We must use the raw body for signature verification
    payload = await request.body()

    try:
        # This single line verifies the signature and parses the JSON
        event = stripe.Webhook.construct_event(
            payload, stripe_signature, ENDPOINT_SECRET
        )
    except ValueError as e:
        print("Invalid payload")
        raise HTTPException(status_code=400, detail="Invalid payload")
    except stripe.error.SignatureVerificationError as e:
        print("Invalid signature")
        raise HTTPException(status_code=400, detail="Invalid signature")
    
    session = event['data']['object']
    # --- Handle the Successful Payment ---
    if event['type'] == 'checkout.session.completed':
        
        
        # FIX: Use getattr() instead of .get() for the new Stripe SDK
        user_id = getattr(session, 'client_reference_id', None)
        customer_id = getattr(session, 'customer', None)
        subscription_id = getattr(session, 'subscription', None)
        amount_total = getattr(session, 'amount_total', None)
        payment_intent = getattr(session, 'payment_intent', None)

        if user_id:
            logger.info(f"APP-LOG-💳 PAYMENT INITIATED: Received Stripe event for User ID [{user_id}]")
            user_ref = db.collection('users').document(user_id)
            doc = user_ref.get() # Firestore still uses .get(), this is safe

            if doc.exists:
                # The Happy Path
                current_unix_time = int(time.time())
                user_ref.update({
                    'validSubscription': True,
                    'isPro': True,
                    'subscriptionEnd': current_unix_time + (31 * 24 * 60 * 60),
                    'requestLimit': PRO_SUB_LIMIT, 
                    'projectLimit': 10,
                    'stripeCustomerId': customer_id,
                    'stripeSubscriptionId': subscription_id
                })
                print(f"Success: Upgraded {user_id}")
            else:
                # The Nightmare Path
                print(f"CRITICAL ERROR: Payment received but user {user_id} not found!")
                logger.error(f"APP-LOG-❌ STRANDED PAYMENT: User [{user_id}] paid but document was not found in Firestore!")
                db.collection('stranded_payments').add({
                    'attempted_user_id': user_id,
                    'stripe_customer': customer_id,
                    'payment_intent': payment_intent,
                    'amount_paid': amount_total,
                    'timestamp': int(time.time()),
                    'status': 'needs_manual_review'
                })
    # Return a 200 OK so Stripe knows we received it
    
    # 1. THE CANCELLATION (User clicked 'Cancel' in Portal)
    if event['type'] == 'customer.subscription.updated':
        # If Stripe says this sub will NOT renew
        if getattr(session, 'cancel_at_period_end', False):
            # Find the user by Stripe Customer ID
            customer_id = getattr(session, 'customer', None)
           #users = db.collection('users').where('stripeCustomerId', '==', customer_id).stream()
            users = db.collection('users').where(filter=FieldFilter('stripeCustomerId', '==', customer_id)).stream()
            
            for u in users:
                u.reference.update({'cancelAtPeriodEnd': True})
                logger.info(f"APP-LOG-📅 SUBSCRIPTION CANCELED: User [{u.id}] will lose Pro at end of period.")

    # 2. THE EXPIRATION (The month is over, time to revoke)
    if event['type'] == 'customer.subscription.deleted':
        customer_id = getattr(session, 'customer', None)
        #users = db.collection('users').where('stripeCustomerId', '==', customer_id).stream()
        users = db.collection('users').where(filter=FieldFilter('stripeCustomerId', '==', customer_id)).stream()
        
        for u in users:
            # Drop them back to Free Tier limits
            u.reference.update({
                'isPro': False,
                'validSubscription': False,
                'projectLimit': 1,      # Reset to Free limit
                'requestLimit': DEFAULT_USER_REQUEST_LIMIT,     # Reset to Free limit
                'cancelAtPeriodEnd': False
            })
            logger.info(f"APP-LOG-🚫 PRO REVOKED: User [{u.id}] has been moved back to Free Tier.")

    return {"status": "success"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8090)


''' Deprecated 20260502
# --- MODIFIED ENDPOINT: send-alert ---
@app.post("/send-alert")
async def send_alert(
    request: AlertRequest,
    authorization: Optional[str] = Header(None),
    x_user_id: Optional[str] = Header(None),
):
    api_key = None
    if authorization and authorization.startswith("Bearer "):
        api_key = authorization.split("Bearer ")[-1]

    if not x_user_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="X-User-Id header is required for sending alerts.")

    user_profile_ref = db.collection('users').document(x_user_id)
    
    
    @firestore.transactional
    def manage_user_profile(transaction, user_profile_ref_in_tx):
        snapshot = user_profile_ref_in_tx.get(transaction=transaction)
        current_unix_time = int(time.time())

        user_profile_data = {}
        had_limit_notification_sent_before = False # Track the flag's state before this request
        
        if snapshot.exists:
            user_profile_data = snapshot.to_dict()
            had_limit_notification_sent_before = user_profile_data.get('limitNotificationSent', False) # Get current state

            user_profile_data['lastRequestTime'] = current_unix_time
            user_profile_data['requestCounter'] = user_profile_data.get('requestCounter', 0) + 1
            user_profile_data['totalRequests'] = user_profile_data.get('totalRequests', 0) + 1
            
            # Determine the effective requestLimit for this user
            current_request_limit = user_profile_data.get('requestLimit', DEFAULT_USER_PROFILE_REQUEST_LIMIT)

            # NEW LOGIC: Check if limit is now exceeded and the one-time notification hasn't been sent yet
            if user_profile_data['requestCounter'] > current_request_limit and not had_limit_notification_sent_before:
                user_profile_data['limitNotificationSent'] = True # Set the flag
        else:
            user_profile_data = {
                'joinTime': current_unix_time,
                'lastRequestTime': current_unix_time,
                'requestCounter': 1,
                'requestLimit': DEFAULT_USER_PROFILE_REQUEST_LIMIT,
                'subscriptionEnd': current_unix_time, 
                'totalRequests': 1,
                'validSubscription': False, 
                'projectsCreatedCount': 0,
                'limitNotificationSent': False, # Initialize the flag for a new profile
            }
            user_profile_data['firstApiKeyUsed'] = api_key 

        transaction.set(user_profile_ref_in_tx, user_profile_data)
        
        # Return the updated profile data and a boolean indicating if the limit notification was *just* triggered
        return {
            "profile": user_profile_data, 
            "limit_notification_just_triggered": user_profile_data.get('limitNotificationSent', False) and not had_limit_notification_sent_before
        }

    rejection_message_title = None
    rejection_message_body = None
    user_fcm_token = None
    should_send_one_time_fcm = False # This will be set by the transaction result

    try:
        transaction_result = manage_user_profile(db.transaction(), user_profile_ref)
        updated_user_profile_data = transaction_result["profile"]
        should_send_one_time_fcm = transaction_result["limit_notification_just_triggered"]

        print(f"User profile for user ID '{x_user_id}' updated in 'users' collection. Total requests: {updated_user_profile_data['totalRequests']}")
        
        # Retrieve the FCM token from the *updated* profile data
        user_fcm_token = updated_user_profile_data.get('fcmToken')
        current_unix_time = int(time.time())

        # Check Subscription Validity (this block determines if the user is truly rejected)
        is_valid_sub = updated_user_profile_data.get('validSubscription', False)
        sub_end_time = updated_user_profile_data.get('subscriptionEnd', 0)
        
        # For now, only checking requestCounter < RequestLimit for non-subscribers
        if not is_valid_sub or current_unix_time >= sub_end_time:
            current_request_limit = updated_user_profile_data.get('requestLimit', DEFAULT_USER_PROFILE_REQUEST_LIMIT)
            if updated_user_profile_data['requestCounter'] > current_request_limit:
                rejection_message_title = "Request Limit Exceeded"
                rejection_message_body = f"Consider subscribing for unlimited requests."
                
                # Send the direct FCM ONLY if the flag was just flipped (one-time notification)
                if user_fcm_token and should_send_one_time_fcm: 
                    await send_direct_fcm_notification(
                        user_fcm_token,
                        rejection_message_title, 
                        rejection_message_body
                    )   
                raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=rejection_message_body)

    except HTTPException as e:
        raise e 
    except Exception as e:
        print(f"Error managing user profile for user ID '{x_user_id}': {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to process user profile: {str(e)}")

    # --- Project ID Validation (unchanged - just validating project exists and is enabled) ---
    if not request.projectId or len(request.projectId) < 8:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid projectId. Must be at least 8 characters.")

    project_doc_ref = db.collection('projects').document(request.projectId)
    project_snapshot = project_doc_ref.get()

    if not project_snapshot.exists:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Project ID '{request.projectId}' not found.")
    
    project_data = project_snapshot.to_dict()
    if not project_data.get('enabled', False):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=f"Project '{request.projectId}' is currently disabled.")
    
    # --- FCM Message Sending (unchanged) ---
    current_timestamp_ms = int(time.time() * 1000)

    topic = f"project_{request.projectId}"
    mId = str(uuid.uuid4())
    message = messaging.Message(
        notification=messaging.Notification(title=request.title, body=request.message),
        data={
            "title": request.title,
            "message": request.message,
            "messageId": mId,
            "timestamp": str(current_timestamp_ms),
            "projectId": request.projectId,
            "sender_identifier": x_user_id
        },
        topic=topic,
        android=messaging.AndroidConfig(priority="high"),
        apns=messaging.APNSConfig(payload=messaging.APNSPayload(aps=messaging.Aps(content_available=True))),
    )
    

    try:
        response = messaging.send(message)
        print(f"Successfully sent message to topic {topic} with ID: {response}")
        return {
            "message": "Alert sent successfully",
            "fcm_message_id": response,
            "message_id": mId,  # Return messageId for debugging
            "server_timestamp_ms": current_timestamp_ms
        }
    except Exception as e:
        print(f"Error sending message: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to send alert: {str(e)}")

@firestore.transactional
def manage_user_profile(transaction, user_profile_ref_in_tx):
    snapshot = user_profile_ref_in_tx.get(transaction=transaction)
    current_unix_time = int(time.time())
    current_month_str = datetime.datetime.fromtimestamp(current_unix_time).strftime('%Y-%m')
    
    # COMPLETE SCHEMA INITIALIZATION
    user_profile_data = snapshot.to_dict() if snapshot.exists else {
        'joinTime': current_unix_time,
        'lastRequestTime': current_unix_time,
        'lastRequestMonth': current_month_str,
        'requestCounter': 0,
        'totalRequests': 0,
        'requestLimit': 25, # Explicitly tracking the default tier limit
        'validSubscription': False,
        'subscriptionEnd': current_unix_time, # Default to current time (expired)
        'projectsCreatedCount': 0,
        'limitNotificationSent': False,
    }
    if not snapshot.exists:
        user_profile_data['firstApiKeyUsed'] = api_key
    
    had_limit_notification_sent_before = user_profile_data.get('limitNotificationSent', False)
    # Monthly Reset Logic
    if user_profile_data.get('lastRequestMonth') != current_month_str:
        user_profile_data['requestCounter'] = 0
        user_profile_data['lastRequestMonth'] = current_month_str
        user_profile_data['limitNotificationSent'] = False # Reset the warning for the new month
    # Increment Tracking Fields
    user_profile_data['lastRequestTime'] = current_unix_time
    user_profile_data['requestCounter'] += 1
    user_profile_data['totalRequests'] += 1
    # Dynamic limits based on subscription
    is_valid_sub = user_profile_data.get('validSubscription', False)
    sub_end_time = user_profile_data.get('subscriptionEnd', 0)
    
    if is_valid_sub and current_unix_time < sub_end_time:
        current_request_limit = 1000
    else:
        current_request_limit = user_profile_data.get('requestLimit', 25) 
    # Check if they are over the limit
    is_rate_limited = user_profile_data['requestCounter'] > current_request_limit
    # Trigger notification flag if they just hit the limit
    if is_rate_limited and not had_limit_notification_sent_before:
        user_profile_data['limitNotificationSent'] = True
    transaction.set(user_profile_ref_in_tx, user_profile_data)
    
    return {
        "profile": user_profile_data, 
        "limit_notification_just_triggered": user_profile_data.get('limitNotificationSent', False) and not had_limit_notification_sent_before,
        "is_rate_limited": is_rate_limited
    }


BURST_CAPACITY = 30
REFILL_RATE = 0.5  # 1 token every 2 seconds

@firestore.transactional
def enforce_limits_transaction(transaction, user_ref):
    snapshot = user_ref.get(transaction=transaction)
    if not snapshot.exists:
        raise HTTPException(status_code=401, detail="User not found")
        
    user_data = snapshot.to_dict()
    
    # 1. Check Hard Monthly Quota First
    if user_data.get('requestCounter', 0) >= user_data.get('requestLimit', 25):
        raise HTTPException(status_code=403, detail="Monthly limit reached.")

    # 2. Token Bucket Logic (Burst/Sustain)
    now = time.time()
    last_check = user_data.get('lastRateLimitCheck', now)
    current_tokens = user_data.get('availableTokens', BURST_CAPACITY)
    
    time_passed = now - last_check
    new_tokens = current_tokens + (time_passed * REFILL_RATE)
    current_tokens = min(BURST_CAPACITY, new_tokens)
    
    # 3. Approve or Reject
    if current_tokens >= 1:
        # Atomic update: Deduct token, update timestamp, and increment monthly usage
        transaction.update(user_ref, {
            'availableTokens': current_tokens - 1,
            'lastRateLimitCheck': now,
            'requestCounter': firestore.Increment(1) 
        })
        return True
    else:
        return False
        
# --- MODIFIED ENDPOINT: send-alert ---
@app.post("/send-alert")
async def send_alert(
    request: AlertRequest,
    authorization: Optional[str] = Header(None),
    x_user_id: Optional[str] = Header(None),
):


    if not x_user_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="X-User-Id header is required for sending alerts.")

    # --- 1. Project ID & Ownership Security Check ---
    if not request.projectId or len(request.projectId) < 8:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid projectId.")

    project_doc_ref = db.collection('projects').document(request.projectId)
    project_snapshot = project_doc_ref.get()

    if not project_snapshot.exists:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Project not found.")
    
    project_data = project_snapshot.to_dict()
    
    # THE BRILLIANT FIX: Does the user sending the alert own this project?
    if project_data.get('createdByInstallId') != x_user_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, 
            detail="Unauthorized: You must be the project creator to send alerts to this project."
        )

    if not project_data.get('enabled', False):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Project is currently disabled.")

    user_profile_ref = db.collection('users').document(x_user_id)
    
    try:
        # 4. Pass the Reference INTO the transaction. 
        # The transaction will do the actual .get() inside to ensure the lock.
        allowed = enforce_limits_transaction(db.transaction(), user_profile_ref)
        
        if not allowed:
            raise HTTPException(
                status_code=429, 
                detail="Rate limit exceeded. Burst capacity reached.",
                headers={"Retry-After": "2"} 
            )
            
    except HTTPException as e:
        raise e 
    except Exception as e:
        print(f"Transaction Error: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

    try:
        transaction_result = manage_user_profile(db.transaction(), user_profile_ref)
        updated_user_profile_data = transaction_result["profile"]
        should_send_one_time_fcm = transaction_result["limit_notification_just_triggered"]
        is_rate_limited = transaction_result["is_rate_limited"]

        print(f"User profile for user ID '{x_user_id}' updated in 'users' collection. Total requests: {updated_user_profile_data['totalRequests']}")
        
        user_fcm_token = updated_user_profile_data.get('fcmToken')

        # Cleaned up logic: We now rely entirely on the transaction's boolean response
        if is_rate_limited:
            rejection_message_title = "Alert Limit Exceeded"
            rejection_message_body = "You have reached your monthly alert limit. Please upgrade to Pro."
            
            # Send the direct FCM ONLY if the flag was just flipped (one-time notification)
            if user_fcm_token and should_send_one_time_fcm: 
                await send_direct_fcm_notification(
                    user_fcm_token,
                    rejection_message_title, 
                    rejection_message_body
                )   
            raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=rejection_message_body)

    except HTTPException as e:
        raise e 
    except Exception as e:
        print(f"Error managing user profile for user ID '{x_user_id}': {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to process user profile: {str(e)}")

    
    # --- FCM Message Sending (unchanged) ---
    current_timestamp_ms = int(time.time() * 1000)

    topic = f"project_{request.projectId}"
    mId = str(uuid.uuid4())
    message = messaging.Message(
        notification=messaging.Notification(title=request.title, body=request.message),
        data={
            "title": request.title,
            "message": request.message,
            "messageId": mId,
            "timestamp": str(current_timestamp_ms),
            "projectId": request.projectId,
            "sender_identifier": x_user_id
        },
        topic=topic,
        android=messaging.AndroidConfig(priority="high"),
        apns=messaging.APNSConfig(payload=messaging.APNSPayload(aps=messaging.Aps(content_available=True))),
    )
    
    try:
        response = messaging.send(message)
        print(f"Successfully sent message to topic {topic} with ID: {response}")
        return {
            "message": "Alert sent successfully",
            "fcm_message_id": response,
            "message_id": mId,  
            "server_timestamp_ms": current_timestamp_ms
        }
    except Exception as e:
        print(f"Error sending message: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to send alert: {str(e)}")
'''



