//
//  cursorhelper.c
//  Magnes
//
//  Created by margooey on 6/2/25.
//

#include "CGSInternal/CGSConnection.h"
#include "CGSInternal/CGSCursor.h"
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>

typedef enum {
    ARROW,
    IBEAM,
    HORIZONTAL_RESIZE,
    VERTICAL_RESIZE,
    DIAGONAL_RESIZE,
    POINTER,
    OTHER
} CursorType;

static CursorType determineResizeDirection(uint8_t *pixelData, int width,
                                           int height) {
    /// Diagonal
    int diagCount1 = 0;
    int diagCount2 = 0;
    int totalCount = 0;

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            size_t idx = ((size_t)y * (size_t)width + (size_t)x) * 4;
            uint8_t alpha = pixelData[idx];
            if (alpha > 10) {
                totalCount++;
                if (x == y) {
                    diagCount1++;
                }
                if (x == (width - y - 1)) {
                    diagCount2++;
                }
            }
        }
    }

    if (totalCount > 0) {
        double frac1 = (double)diagCount1 / (double)totalCount;
        double frac2 = (double)diagCount2 / (double)totalCount;
        if (frac1 == 0 && frac2 == 0.04) {
            return DIAGONAL_RESIZE;
        }
    }

    /// Horizontal/Vertical
    int maxInAnyRow = 0;
    int maxInAnyCol = 0;

    int rowCounts[height];
    int colCounts[width];
    for (int i = 0; i < height; ++i)
        rowCounts[i] = 0;
    for (int i = 0; i < width; ++i)
        colCounts[i] = 0;

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            size_t idx = ((size_t)y * (size_t)width + (size_t)x) * 4;
            uint8_t alpha = pixelData[idx];
            if (alpha > 10) {
                rowCounts[y] += 1;
                colCounts[x] += 1;
            }
        }
        if (rowCounts[y] > maxInAnyRow)
            maxInAnyRow = rowCounts[y];
    }
    for (int x = 0; x < width; ++x) {
        if (colCounts[x] > maxInAnyCol)
            maxInAnyCol = colCounts[x];
    }

    /// These values were checked manually
    switch (maxInAnyRow) {
    case 6:
        return VERTICAL_RESIZE;
    case 8:
        return HORIZONTAL_RESIZE;
    case 10:
        return HORIZONTAL_RESIZE;
    case 14:
        if (maxInAnyCol == 13) {
            return POINTER;
        } else {
            return VERTICAL_RESIZE;
        }
    }
    return OTHER;
}
static CursorType getCursorType(void) {
    int dataSize = 0;
    CGError err = CGSGetGlobalCursorDataSize(_CGSDefaultConnection(), &dataSize);
    if (err != kCGErrorSuccess || dataSize <= 0) {
        fprintf(
            stderr,
            "[Error] GCSGetGlobalCursorDataSize failed with error code %d.\n",
            err);
        return 1;
    }

    uint8_t *pixelData = malloc((size_t)dataSize);
    if (!pixelData) {
        free(pixelData);
        fprintf(stderr, "[Error] Failed to allocate cursor data buffer.\n");
        return 1;
    }

    CGSize cursorSize = {0, 0};
    CGPoint cursorHot = {0, 0};
    int depth = 0;
    int components = 0;
    int bitsPerComp = 0;
    int unknownM = 0; /// Not sure what `m` refers to, but it works

    err = CGSGetGlobalCursorData(_CGSDefaultConnection(), pixelData, &dataSize, &cursorSize,
                                 &cursorHot, &depth, &components, &bitsPerComp,
                                 &unknownM);
    if (err != kCGErrorSuccess) {
        free(pixelData);
        fprintf(stderr,
                "[Error] CGSGetGlobalCursorData failed with error code %d.\n",
                err);
        return 1;
    }

    int width = (int)cursorSize.width;
    int height = (int)cursorSize.height;

    /// For debugging
    /*printf("[Cursor] width=%d, height=%d, depth=%d, components=%d, "
           "bitsPerComp=%d\n",
           width, height, depth, components, bitsPerComp);*/

    if (width > 0 && height > 0) {
        double ratio = (double)width / (double)height;

        if (width == 23 && height == 22) {
            free(pixelData);
            return IBEAM;
        }

        if (ratio == 1) {
            CursorType result =
                determineResizeDirection(pixelData, width, height);
            free(pixelData);
            return result;
        }
    }

    free(pixelData);
    return ARROW;
}

// MARK: - Exposed to Swift
CursorType getCurrentCursorType(void) {
    CursorType type = getCursorType();
    return type;
}

int hideCursor(void) {
    /// Really cool function for hiding the cursor system-wide by `Nick Bolton`
    CFStringRef propertyString = CFStringCreateWithCString(
        NULL, "SetsCursorInBackground", kCFStringEncodingMacRoman);
    CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(),
                             propertyString, kCFBooleanTrue);
    CFRelease(propertyString);

    CGError error = CGDisplayHideCursor(kCGDirectMainDisplay);
    if (error != kCGErrorSuccess) {
        fprintf(stderr, "[Error] CGDisplayHideCursor failed (error = %d)\n",
                error);
    }

    /// CGAssociateMouseAndMouseCursorPosition(true);
    /// The above only works on earlier versions of macOS, the below is required now. I have no idea why.
    CGEventSourceRef eventSourceRef = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventSourceSetLocalEventsSuppressionInterval(eventSourceRef, 0);
    if (eventSourceRef) CFRelease(eventSourceRef);
    return 0;
}

/// Function for preventing the dock from messing with the cursor. Calling more than once flips the flag regardless of boolean value weirdly
void notTodayDock(void) {
    CGSSetDockCursorOverride(_CGSDefaultConnection(), true);
}

int showCursor(void) {
    CGError error = CGDisplayShowCursor(kCGDirectMainDisplay);
    if (error != kCGErrorSuccess) {
        fprintf(stderr, "[Error] CGDisplayShowCursor failed (error = %d)\n", error);
    }
    CGEventSourceRef eventSourceRef = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventSourceSetLocalEventsSuppressionInterval(eventSourceRef, 0);
    if (eventSourceRef) CFRelease(eventSourceRef);
    return 0;
}
