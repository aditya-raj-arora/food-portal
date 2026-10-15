#!/bin/sh
set -u

BASE_URL="${1:-http://127.0.0.1}"
EXPECTED_VERSION="${2:-}"
FAILED=0
ATTEMPTS=0

until PAGE=$(wget -qO- "$BASE_URL/" 2>/dev/null); do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge 15 ]; then
        echo "FAIL  $BASE_URL is not reachable"
        exit 1
    fi
    sleep 1
done

check() {
    if echo "$PAGE" | grep -q "$1"; then
        echo "PASS  $2"
    else
        echo "FAIL  $2"
        FAILED=1
    fi
}

check "<title>Online Food Ordering Portal</title>" "Page title"
check 'id="restaurant"' "Restaurant details section"
check 'id="categories"' "Food categories section"
check 'id="menu"' "Menu section"
check 'class="price"' "Menu prices"
check 'class="status' "Availability labels"
check 'id="offers"' "Promotional offers section"

if wget -q --spider "$BASE_URL/styles.css"; then
    echo "PASS  Stylesheet is served"
else
    echo "FAIL  Stylesheet is served"
    FAILED=1
fi

if [ -n "$EXPECTED_VERSION" ]; then
    SERVED_VERSION=$(wget -qO- "$BASE_URL/version.txt" 2>/dev/null | tr -d '[:space:]')
    if [ "$SERVED_VERSION" = "$EXPECTED_VERSION" ]; then
        echo "PASS  Serving release $EXPECTED_VERSION"
    else
        echo "FAIL  Expected release $EXPECTED_VERSION, got '${SERVED_VERSION}'"
        FAILED=1
    fi
fi

exit "$FAILED"
