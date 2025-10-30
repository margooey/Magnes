//
//  CursorHelper-Bridging-Header.h
//  Magnes
//
//  Created by margooey on 6/2/25.
//

#ifndef CursorHelper_Bridging_Header_h
#define CursorHelper_Bridging_Header_h

typedef enum {
    ARROW = 0,
    IBEAM = 1,
    HORIZONTAL_RESIZE = 2,
    VERTICAL_RESIZE = 3,
    DIAGONAL_RESIZE = 4,
    POINTER = 5,
    OTHER = 6
} CursorType;

CursorType getCurrentCursorType(void);
int hideCursor(void);
void notTodayDock(void);

#endif /* CursorHelper_Bridging_Header_h */
